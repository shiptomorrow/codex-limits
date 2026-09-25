import datetime
import fcntl
import glob
import hashlib
import json
import os
import pathlib
import pwd
import select
import shlex
import shutil
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request


# Logs subscription usage on a server so history continues while the Mac is off.
# Cron runs `log` on a schedule; the Mac later pulls new entries with `export`.
# While the Mac reads usage itself, each export renews a lease that slows the server's checks.
# Credentials never leave the host: entries hold only usage windows and a hashed account ID.
RESPONSE_VERSION = 1
REQUEST_TIMEOUT = 30
RETENTION = 45 * 86400
MAXIMUM_LOG_SIZE = 4_000_000
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"
# Mirrors ClaudeClient.rateLimitBackoffSchedule.
CLAUDE_BACKOFF_SCHEDULE = [10, 60, 3 * 60, 5 * 60]
CRON_MARKER = "# codex-limits-usage-"
# The Claude usage endpoint rate limits one request a minute about every other time.
CRON_SCHEDULES = {"codex": "* * * * *", "claude": "*/2 * * * *"}
# Mirrors ServerUsageLog.macLoggingCheckInterval.
MAC_LOGGING_CHECK_INTERVAL = 10 * 60


class UsageError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def data_directory(home):
    configured = os.environ.get("CODEX_LIMITS_DIR")
    return pathlib.Path(configured).expanduser() if configured else home / ".codex-limits"


def account_hash(provider, account_id):
    if not isinstance(account_id, str) or not account_id:
        return None
    return hashlib.sha256(f"{provider}:{account_id}".encode()).hexdigest()


def read_json(path):
    try:
        with open(path, "rb") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")))
    os.replace(temporary, path)


def codex_home(home):
    configured = os.environ.get("CODEX_HOME")
    return pathlib.Path(configured).expanduser() if configured else home / ".codex"


def claude_root(home):
    configured = os.environ.get("CLAUDE_CONFIG_DIR")
    return pathlib.Path(configured).expanduser() if configured else home / ".claude"


def claude_config_path(home):
    configured = os.environ.get("CLAUDE_CONFIG_DIR")
    return pathlib.Path(configured).expanduser() / ".claude.json" if configured else home / ".claude.json"


def login_shell_path():
    try:
        shell = pwd.getpwuid(os.getuid()).pw_shell or "/bin/sh"
    except KeyError:
        shell = os.environ.get("SHELL") or "/bin/sh"
    try:
        result = subprocess.run(
            [shell, "-lc", 'printf "\\n%s" "$PATH"'],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = result.stdout.decode(errors="replace").splitlines()
    return lines[-1] if lines else ""


def codex_search_path(home):
    """SSH and cron sessions often lack the login PATH that finds codex and node."""
    extra = [
        str(home / ".local/bin"),
        str(home / ".npm-global/bin"),
        str(home / ".bun/bin"),
        str(home / ".volta/bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
    extra += sorted(glob.glob(str(home / ".nvm/versions/node/*/bin")), reverse=True)
    parts = [os.environ.get("PATH", "")]
    if shutil.which("codex") is None:
        parts.insert(0, login_shell_path())
    return os.pathsep.join(part for part in parts + extra if part)


class LineReader:
    def __init__(self, stream, deadline):
        self.fd = stream.fileno()
        self.deadline = deadline
        self.buffer = b""

    def read_line(self):
        while b"\n" not in self.buffer:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                raise TimeoutError
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise EOFError
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.rstrip(b"\r")


def read_responses(reader, ids):
    """Collects JSON-RPC responses by ID, skipping notifications."""
    responses = {}
    while not ids.issubset(responses):
        line = reader.read_line()
        if not line.strip():
            continue
        message = json.loads(line)
        if isinstance(message, dict) and message.get("id") in ids:
            responses[message["id"]] = message
    return responses


def send(process, message):
    process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
    process.stdin.flush()


def rpc_result(response):
    if "error" in response:
        error = response["error"] if isinstance(response["error"], dict) else {}
        raise UsageError(f"rpc:{error.get('message') or ''}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise UsageError("invalidResponse")
    return result


def clamped_remaining(used):
    return min(max(100 - float(used), 0), 100)


def codex_windows(rate_limits):
    """Mirrors CodexClient.decode for the main limit's windows."""
    by_id = rate_limits.get("rateLimitsByLimitId")
    snapshots = by_id if isinstance(by_id, dict) else {"codex": rate_limits.get("rateLimits")}
    main = snapshots.get("codex") or rate_limits.get("rateLimits")
    if not isinstance(main, dict):
        raise UsageError("mainLimitMissing")
    windows = []
    for key in ("primary", "secondary"):
        window = main.get(key)
        if (
            isinstance(window, dict)
            and isinstance(window.get("usedPercent"), (int, float))
            and isinstance(window.get("windowDurationMins"), int)
            and isinstance(window.get("resetsAt"), (int, float))
        ):
            windows.append({
                "minutes": window["windowDurationMins"],
                "remaining": clamped_remaining(window["usedPercent"]),
                "resetsAt": int(window["resetsAt"]),
            })
    if not windows:
        raise UsageError("mainLimitMissing")
    return windows


def read_codex(home, config):
    auth = read_json(codex_home(home) / "auth.json") or {}
    tokens = auth.get("tokens") if isinstance(auth.get("tokens"), dict) else {}
    account = account_hash("codex", tokens.get("account_id"))

    search_path = config.get("path") or codex_search_path(home)
    executable = config.get("codex")
    if not executable or not os.access(executable, os.X_OK):
        executable = shutil.which("codex", path=search_path)
    if executable is None:
        raise UsageError("cliNotFound")

    process = subprocess.Popen(
        [executable, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=dict(os.environ, PATH=search_path),
    )
    try:
        reader = LineReader(process.stdout, time.monotonic() + REQUEST_TIMEOUT)
        send(process, {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codex-limits",
                    "title": "Codex Limits",
                    "version": config.get("appVersion") or "0.1.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        })
        rpc_result(read_responses(reader, {1})[1])
        send(process, {"method": "initialized"})
        send(process, {"id": 2, "method": "account/rateLimits/read"})
        return account, codex_windows(rpc_result(read_responses(reader, {2})[2]))
    except TimeoutError:
        raise UsageError("timedOut")
    except (EOFError, BrokenPipeError, ValueError):
        raise UsageError("invalidResponse")
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def claude_credentials(home):
    credentials = read_json(claude_root(home) / ".credentials.json")
    if credentials is None and sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            if result.returncode == 0:
                credentials = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            credentials = None
    oauth = credentials.get("claudeAiOauth") if isinstance(credentials, dict) else None
    if not isinstance(oauth, dict) or not isinstance(oauth.get("accessToken"), str) or not oauth["accessToken"]:
        return None
    return oauth


def claude_reset(value):
    """Drops sub-second jitter, like ClaudeClient.date, so windows don't split."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(parsed.replace(microsecond=0).timestamp())


def claude_windows(body):
    windows = []
    for key, minutes in (("five_hour", 300), ("seven_day", 10_080)):
        window = body.get(key)
        if not isinstance(window, dict) or not isinstance(window.get("utilization"), (int, float)):
            continue
        resets_at = claude_reset(window.get("resets_at"))
        if resets_at is None:
            continue
        windows.append({
            "minutes": minutes,
            "remaining": clamped_remaining(window["utilization"]),
            "resetsAt": resets_at,
        })
    if not windows:
        raise UsageError("mainLimitMissing")
    return windows


def read_claude(home, config):
    claude_config = read_json(claude_config_path(home)) or {}
    oauth_account = claude_config.get("oauthAccount")
    oauth_account = oauth_account if isinstance(oauth_account, dict) else {}
    account = account_hash("claude", oauth_account.get("accountUuid"))

    oauth = claude_credentials(home)
    if oauth is None:
        raise UsageError("credentialsNotFound")
    # The token is never refreshed here: refresh tokens rotate, and refreshing
    # outside Claude Code would sign Claude Code out on this host.
    expires_at = oauth.get("expiresAt")
    if isinstance(expires_at, (int, float)) and expires_at / 1000 <= time.time():
        raise UsageError("authenticationFailed")

    request = urllib.request.Request(CLAUDE_USAGE_URL, headers={
        "Authorization": f"Bearer {oauth['accessToken']}",
        "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json",
        "User-Agent": f"codex-limits/{config.get('appVersion') or '0.1.0'}",
    })
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise UsageError("authenticationFailed")
        if error.code == 429:
            retry_after = error.headers.get("Retry-After")
            raise UsageError(f"rateLimited:{retry_after or 0}")
        if 500 <= error.code <= 599:
            raise UsageError("serviceUnavailable")
        raise UsageError("requestFailed")
    except TimeoutError:
        raise UsageError("timedOut")
    except (urllib.error.URLError, OSError):
        raise UsageError("connectionFailed")
    try:
        parsed = json.loads(body)
    except ValueError:
        raise UsageError("invalidResponse")
    if not isinstance(parsed, dict):
        raise UsageError("invalidResponse")
    return account, claude_windows(parsed)


def read_usage(provider, home, config):
    if provider == "codex":
        return read_codex(home, config)
    if provider == "claude":
        return read_claude(home, config)
    raise ValueError(f"Unknown provider: {provider}")


def paths(home, provider):
    root = data_directory(home)
    return {
        "root": root,
        "config": root / f"{provider}-config.json",
        "state": root / f"{provider}-state.json",
        "log": root / f"{provider}-usage.jsonl",
        "lock": root / f"{provider}.lock",
        "mac": root / f"{provider}-mac.json",
    }


def read_entries(log_path):
    entries = []
    try:
        with open(log_path, "rb") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and isinstance(entry.get("t"), (int, float)):
                    entries.append(entry)
    except OSError:
        pass
    return entries


def append_entry(log_path, entry, now):
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry, separators=(",", ":")) + "\n")
    if log_path.stat().st_size > MAXIMUM_LOG_SIZE:
        kept = [item for item in read_entries(log_path) if item["t"] >= now - RETENTION]
        temporary = log_path.with_name(log_path.name + ".tmp")
        temporary.write_text("".join(json.dumps(item, separators=(",", ":")) + "\n" for item in kept))
        os.replace(temporary, log_path)


def log_usage(provider, home, now=None):
    """Records one reading, writing an entry only when the account or windows changed."""
    files = paths(home, provider)
    files["root"].mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(files["lock"], "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return read_json(files["state"]) or {}

        now = time.time() if now is None else now
        state = read_json(files["state"]) or {}
        if now < state.get("backoffUntil", 0):
            return state
        mac = read_json(files["mac"]) or {}
        # Cron start times drift by a few seconds, so allow slack to keep the checks on schedule.
        if now < mac.get("loggingUntil", 0) and now - state.get("lastRunAt", 0) < MAC_LOGGING_CHECK_INTERVAL - 30:
            return state

        config = read_json(files["config"]) or {}
        try:
            account, windows = read_usage(provider, home, config)
        except UsageError as error:
            code = error.code
            if code.startswith("rateLimited:"):
                try:
                    server_delay = float(code.split(":", 1)[1])
                except ValueError:
                    server_delay = 0
                count = state.get("consecutiveRateLimits", 0)
                delay = max(CLAUDE_BACKOFF_SCHEDULE[min(count, len(CLAUDE_BACKOFF_SCHEDULE) - 1)], server_delay)
                state["consecutiveRateLimits"] = count + 1
                state["backoffUntil"] = now + delay
                code = "rateLimited"
            state.update(lastRunAt=now, lastError=code)
            write_json(files["state"], state)
            return state

        entries = read_entries(files["log"])
        last = entries[-1] if entries else None
        if last is None or last.get("account") != account or last.get("windows") != windows:
            append_entry(files["log"], {"t": now, "account": account, "windows": windows}, now)
        state = {"lastRunAt": now, "lastError": None, "lastSuccessAt": now}
        write_json(files["state"], state)
        return state


def cron_lines():
    try:
        result = subprocess.run(
            ["crontab", "-l"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
        )
    except FileNotFoundError:
        raise UsageError("cronMissing")
    # `crontab -l` exits non-zero when the user has no crontab yet.
    return result.stdout.decode(errors="replace").splitlines() if result.returncode == 0 else []


def write_cron_lines(lines):
    text = "".join(line + "\n" for line in lines)
    result = subprocess.run(
        ["crontab", "-"], input=text.encode(),
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10,
    )
    if result.returncode != 0:
        raise UsageError("cronFailed")


def is_installed(provider):
    try:
        return any(line.endswith(CRON_MARKER + provider) for line in cron_lines())
    except UsageError:
        return False


def install(provider, home, app_version):
    files = paths(home, provider)
    files["root"].mkdir(mode=0o700, parents=True, exist_ok=True)
    script = pathlib.Path(__file__).resolve()
    config = {"appVersion": app_version}
    if provider == "codex":
        search_path = codex_search_path(home)
        config["path"] = search_path
        config["codex"] = shutil.which("codex", path=search_path)
    write_json(files["config"], config)

    command = " ".join(shlex.quote(part) for part in (sys.executable, str(script), "log", provider))
    lines = [line for line in cron_lines() if not line.endswith(CRON_MARKER + provider)]
    lines.append(f"{CRON_SCHEDULES[provider]} {command} >/dev/null 2>&1 {CRON_MARKER}{provider}")
    write_cron_lines(lines)
    state = log_usage(provider, home)
    return {"installed": True, "state": state}


def uninstall(provider):
    lines = cron_lines()
    kept = [line for line in lines if not line.endswith(CRON_MARKER + provider)]
    if kept != lines:
        write_cron_lines(kept)
    return {"installed": False}


def export(provider, home, since, mac_logging_until=None):
    """Returns entries newer than `since` and records how long the Mac expects to keep reading usage."""
    files = paths(home, provider)
    if mac_logging_until is not None:
        files["root"].mkdir(mode=0o700, parents=True, exist_ok=True)
        write_json(files["mac"], {"loggingUntil": mac_logging_until})
    mac = read_json(files["mac"]) or {}
    return {
        "installed": is_installed(provider),
        "macLoggingUntil": mac.get("loggingUntil", 0),
        "state": read_json(files["state"]) or {},
        "entries": [entry for entry in read_entries(files["log"]) if entry["t"] > since],
    }


def main():
    command, provider = sys.argv[1], sys.argv[2]
    if provider not in ("codex", "claude"):
        raise ValueError(f"Unknown provider: {provider}")
    home = pathlib.Path.home()
    try:
        if command == "install":
            result = install(provider, home, sys.argv[3] if len(sys.argv) > 3 else "0.1.0")
        elif command == "uninstall":
            result = uninstall(provider)
        elif command == "export":
            result = export(
                provider, home,
                float(sys.argv[3]) if len(sys.argv) > 3 else 0,
                float(sys.argv[4]) if len(sys.argv) > 4 else None,
            )
        elif command == "log":
            log_usage(provider, home)
            return
        else:
            raise ValueError(f"Unknown command: {command}")
    except UsageError as error:
        result = {"error": error.code}
    result["version"] = RESPONSE_VERSION
    json.dump(result, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

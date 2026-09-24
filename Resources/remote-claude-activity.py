import base64
import datetime
import fcntl
import json
import os
import pathlib
import sys
import traceback


# Mirrors ClaudeActivityCache in ClaudeActivity.swift so remote runtime matches local runtime.
CACHE_VERSION = 1
GUARD_LENGTH = 1024
MAXIMUM_SESSION_FILE_SIZE = 200_000_000
RETENTION = 45 * 86400
IDLE_GAP = 15 * 60


def timestamp_seconds(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def parse_line(line):
    """Returns [date, is_prompt, is_sidechain] for a conversation message."""
    if b'"user"' not in line and b'"assistant"' not in line:
        return None
    try:
        obj = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(obj, dict):
        return None
    kind = obj.get("type")
    if kind not in ("user", "assistant") or obj.get("isMeta") is True:
        return None
    date = timestamp_seconds(obj.get("timestamp"))
    if date is None:
        return None

    is_prompt = False
    if kind == "user" and obj.get("isCompactSummary") is not True:
        message = obj.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str):
            is_prompt = True
        elif isinstance(content, list):
            is_prompt = not any(
                isinstance(block, dict) and block.get("type") == "tool_result"
                for block in content
            )
    return [date, is_prompt, obj.get("isSidechain") is True]


def parse_file(path, offset):
    events = []
    consumed = 0
    with path.open("rb") as handle:
        handle.seek(offset)
        for line in handle:
            if not line.endswith(b"\n"):
                break
            consumed += len(line)
            event = parse_line(line.rstrip(b"\r\n"))
            if event is not None:
                events.append(event)
    return events, consumed


def prefix_guard(path, parsed_offset):
    count = min(GUARD_LENGTH, parsed_offset)
    if count <= 0:
        return ""
    with path.open("rb") as handle:
        return base64.b64encode(handle.read(count)).decode("ascii")


def claude_root(home):
    configured = os.environ.get("CLAUDE_CONFIG_DIR")
    return pathlib.Path(configured).expanduser() if configured else home / ".claude"


def selected_files(since, projects_root):
    files = []
    if not projects_root.is_dir():
        return files
    for directory, _, names in os.walk(projects_root):
        for name in names:
            if not name.endswith(".jsonl") or name.startswith("."):
                continue
            path = pathlib.Path(directory) / name
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime < since or stat.st_size > MAXIMUM_SESSION_FILE_SIZE:
                continue
            files.append((str(path.relative_to(projects_root)), path))
    return sorted(files, key=lambda item: item[0])


def save_cache(cache_path, store):
    cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = cache_path.with_name(f"{cache_path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(store, handle, separators=(",", ":"))
    temporary.chmod(0o600)
    os.replace(temporary, cache_path)


def update_cache(cache_path, files, now):
    try:
        with cache_path.open("r", encoding="utf-8") as handle:
            store = json.load(handle)
        if store.get("version") != CACHE_VERSION:
            raise ValueError("cache version changed")
    except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
        store = {"version": CACHE_VERSION, "files": {}}

    changed = False
    for key, path in files:
        stat = path.stat()
        size = stat.st_size
        modification_time = stat.st_mtime_ns
        entry = store["files"].get(key)
        if entry is not None:
            if size == entry["observed_size"] and modification_time == entry["modification_time"]:
                continue
            if (
                size < entry["parsed_offset"]
                or prefix_guard(path, entry["parsed_offset"]) != entry["prefix_guard"]
            ):
                # The file was rewritten, so replace its events.
                entry = None

        if entry is None:
            entry = {"parsed_offset": 0, "events": []}
            store["files"][key] = entry
        events, consumed = parse_file(path, entry["parsed_offset"])
        entry["events"].extend(events)
        entry["parsed_offset"] += consumed
        entry["observed_size"] = size
        entry["modification_time"] = modification_time
        entry["prefix_guard"] = prefix_guard(path, entry["parsed_offset"])
        changed = True

    cutoff = (now - RETENTION) * 1_000_000_000
    expired = [key for key, entry in store["files"].items() if entry["modification_time"] < cutoff]
    for key in expired:
        del store["files"][key]
    if changed or expired:
        save_cache(cache_path, store)
    return [(key, store["files"][key]) for key, _ in files]


def turn_intervals(events):
    """A turn runs from a prompt through its last message; long waits split it."""
    result = []
    segment = None
    for date, is_prompt, _ in events:
        if is_prompt:
            if segment and segment[1] > segment[0]:
                result.append(segment)
            segment = [date, date]
        elif segment is not None and date - segment[1] <= IDLE_GAP:
            segment[1] = max(segment[1], date)
        else:
            # Long waits inside a turn are usually permission prompts.
            if segment and segment[1] > segment[0]:
                result.append(segment)
            segment = [date, date]
    if segment and segment[1] > segment[0]:
        result.append(segment)
    return result


def intervals(entries, since, now, includes_subagents=False):
    result = []
    for key, entry in entries:
        is_subagent_file = "/subagents/" in f"/{key}"
        for sidechain in (False, True):
            is_subagent = is_subagent_file or sidechain
            if is_subagent and not includes_subagents:
                continue
            subagent_id = None
            if is_subagent:
                subagent_id = f"claude:{key}{':sidechain' if sidechain and not is_subagent_file else ''}"
            events = [event for event in entry["events"] if event[2] == sidechain]
            for start, end in turn_intervals(events):
                if end >= since and start <= now:
                    result.append({
                        "start": start,
                        "end": end,
                        "isFastMode": False,
                        "subagentID": subagent_id,
                    })
    return result


def main():
    since = float(sys.argv[1])
    now = float(sys.argv[2])
    includes_subagents = len(sys.argv) > 3 and sys.argv[3] == "1"
    root = claude_root(pathlib.Path.home())
    cache_directory = root / "codex-limits"
    cache_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache_path = cache_directory / "remote-claude-events-v1.json"
    lock_path = cache_directory / "remote-claude-events-v1.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files = selected_files(since, root / "projects")
        entries = update_cache(cache_path, files, now)
        json.dump(
            {"version": 1, "intervals": intervals(entries, since, now, includes_subagents)},
            sys.stdout,
            separators=(",", ":"),
        )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import unittest.mock
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "remote_usage", Path(__file__).resolve().parents[1] / "Resources/remote-usage.py"
)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys
assert sys.argv[1:] == ["app-server"], sys.argv
used = int(os.environ.get("FAKE_USED", "12"))
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    if message["method"] == "initialize":
        print(json.dumps({"method": "notice"}), flush=True)
        result = {}
    else:
        result = {"rateLimits": {"limitId": "codex", "primary": {
            "usedPercent": used, "windowDurationMins": 300, "resetsAt": 2000000000}}}
    print(json.dumps({"id": message["id"], "result": result}), flush=True)
'''


class RemoteUsageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        environment = patch.dict(os.environ, {"CODEX_LIMITS_DIR": str(self.home / "data")})
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("CODEX_HOME", None)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def install_fake_codex(self):
        bin_directory = self.home / "bin"
        bin_directory.mkdir()
        codex = bin_directory / "codex"
        codex.write_text(FAKE_CODEX)
        codex.chmod(codex.stat().st_mode | stat.S_IXUSR)
        (self.home / ".codex").mkdir()
        (self.home / ".codex/auth.json").write_text(
            json.dumps({"tokens": {"account_id": "account-123"}})
        )
        os.environ["PATH"] = f"{bin_directory}{os.pathsep}{os.environ['PATH']}"

    def test_logs_codex_windows_only_when_they_change(self):
        self.install_fake_codex()

        usage.log_usage("codex", self.home, now=100)
        usage.log_usage("codex", self.home, now=160)
        os.environ["FAKE_USED"] = "13"
        state = usage.log_usage("codex", self.home, now=220)

        entries = usage.export("codex", self.home, 0)["entries"]
        self.assertEqual([entry["t"] for entry in entries], [100, 220])
        self.assertEqual(entries[0]["account"], usage.account_hash("codex", "account-123"))
        self.assertEqual(
            entries[1]["windows"],
            [{"minutes": 300, "remaining": 87.0, "resetsAt": 2000000000}],
        )
        self.assertEqual(state["lastRunAt"], 220)
        self.assertIsNone(state["lastError"])
        self.assertEqual([entry["t"] for entry in usage.export("codex", self.home, 100)["entries"]], [220])

    def test_records_missing_cli_as_logger_error(self):
        with patch.object(usage, "cli_search_path", return_value=str(self.home)):
            state = usage.log_usage("codex", self.home, now=100)

        self.assertEqual(state["lastError"], "cliNotFound")
        self.assertEqual(usage.export("codex", self.home, 0)["entries"], [])

    def test_claude_rate_limit_backs_off(self):
        (self.home / ".claude").mkdir()
        (self.home / ".claude/.credentials.json").write_text(json.dumps({
            "claudeAiOauth": {"accessToken": "token"}
        }))
        error = usage.urllib.error.HTTPError(usage.CLAUDE_USAGE_URL, 429, "", {"Retry-After": "0"}, None)
        with patch.object(usage.urllib.request, "urlopen", side_effect=error) as urlopen:
            first = usage.log_usage("claude", self.home, now=100)
            usage.log_usage("claude", self.home, now=105)

        self.assertEqual(first["lastError"], "rateLimited")
        self.assertEqual(first["backoffUntil"], 160)
        self.assertEqual(urlopen.call_count, 1)

    def test_pauses_while_mac_pings(self):
        self.install_fake_codex()
        usage.log_usage("codex", self.home, now=100)
        self.assertEqual(usage.ping("codex", self.home, 120, now=150), {"macLoggingUntil": 270})
        self.assertEqual(usage.export("codex", self.home, 0)["macLoggingUntil"], 270)

        os.environ["FAKE_USED"] = "13"
        skipped = usage.log_usage("codex", self.home, now=260)
        self.assertEqual(skipped["lastRunAt"], 100)
        resumed = usage.log_usage("codex", self.home, now=280)
        self.assertEqual(resumed["lastRunAt"], 280)
        self.assertEqual(len(usage.export("codex", self.home, 0)["entries"]), 2)

    def test_ping_lease_is_capped(self):
        until = usage.ping("claude", self.home, 86400, now=100)["macLoggingUntil"]
        self.assertEqual(until, 100 + usage.MAXIMUM_MAC_LEASE)

    def test_claude_checks_every_ninety_seconds(self):
        self.write_claude_credentials()
        body = json.dumps({"five_hour": {"utilization": 1, "resets_at": "2026-09-25T20:30:00Z"}}).encode()
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = body
        with patch.object(usage.urllib.request, "urlopen", return_value=response) as urlopen:
            # Cron ticks every 30 seconds.
            runs = [usage.log_usage("claude", self.home, now=t)["lastRunAt"] for t in range(0, 210, 30)]

        self.assertEqual(runs, [0, 0, 0, 90, 90, 90, 180])
        self.assertEqual(urlopen.call_count, 3)

    def write_claude_credentials(self, expires_at=None):
        oauth = {"accessToken": "token"}
        if expires_at is not None:
            oauth["expiresAt"] = expires_at
        (self.home / ".claude").mkdir(exist_ok=True)
        (self.home / ".claude/.credentials.json").write_text(json.dumps({"claudeAiOauth": oauth}))

    def test_claude_renews_expired_login_through_claude_code(self):
        self.write_claude_credentials(expires_at=1000)
        renewed = lambda home, config: self.write_claude_credentials(expires_at=4102444800000) or True
        with patch.object(usage, "renew_claude_login", side_effect=renewed) as renew, \
                patch.object(usage.urllib.request, "urlopen", side_effect=usage.urllib.error.URLError("offline")) as urlopen:
            state = usage.log_usage("claude", self.home, now=100)

        renew.assert_called_once()
        urlopen.assert_called_once()
        self.assertEqual(state["lastError"], "connectionFailed")

    def test_claude_retries_failed_login_renewal_sparingly(self):
        self.write_claude_credentials(expires_at=1000)
        with patch.object(usage, "renew_claude_login", return_value=False) as renew, \
                patch.object(usage.urllib.request, "urlopen") as urlopen:
            first = usage.log_usage("claude", self.home, now=100)
            usage.log_usage("claude", self.home, now=200)
            usage.log_usage("claude", self.home, now=100 + usage.CLAUDE_LOGIN_RETRY_INTERVAL)

        self.assertEqual(first["lastError"], "authenticationFailed")
        self.assertEqual(renew.call_count, 2)
        urlopen.assert_not_called()

    def test_renewal_pings_cheapest_model_without_tools(self):
        executable = self.home / "claude"
        executable.write_text("#!/bin/sh\n")
        executable.chmod(0o700)
        (self.home / "data").mkdir()
        with patch.object(usage.subprocess, "run", return_value=unittest.mock.Mock(returncode=0)) as run:
            self.assertTrue(usage.renew_claude_login(self.home, {"claude": str(executable), "path": "/usr/bin"}))

        command = run.call_args.args[0]
        self.assertEqual(command[:3], [str(executable), "-p", "ping"])
        for flag, value in (("--model", "haiku"), ("--effort", "low"), ("--tools", "")):
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertIn("--no-session-persistence", command)

    def test_claude_does_not_send_expired_token(self):
        self.write_claude_credentials(expires_at=1000)
        with patch.object(usage, "renew_claude_login", return_value=True), \
                patch.object(usage.urllib.request, "urlopen") as urlopen:
            state = usage.log_usage("claude", self.home, now=100)

        self.assertEqual(state["lastError"], "authenticationFailed")
        urlopen.assert_not_called()

    def test_claude_windows_drop_subsecond_reset_jitter(self):
        windows = usage.claude_windows({
            "five_hour": {"utilization": 30, "resets_at": "2026-09-25T20:30:00.475365+00:00"},
            "seven_day": {"utilization": 10.5, "resets_at": "2026-09-30T00:00:00.999+00:00"},
        })

        self.assertEqual(windows, [
            {"minutes": 300, "remaining": 70.0, "resetsAt": 1790368200},
            {"minutes": 10080, "remaining": 89.5, "resetsAt": 1790726400},
        ])

    def test_install_replaces_only_its_own_cron_entry(self):
        crontab = ["0 * * * * backup", f"* * * * * old {usage.CRON_MARKER}codex"]
        written = []
        with patch.object(usage, "cron_lines", return_value=crontab), \
                patch.object(usage, "write_cron_lines", side_effect=written.append), \
                patch.object(usage, "log_usage", return_value={"lastRunAt": 1}), \
                patch.object(usage, "cli_search_path", return_value="/usr/bin"):
            result = usage.install("codex", self.home, "1.0")

        self.assertTrue(result["installed"])
        self.assertEqual(written[0][0], "0 * * * * backup")
        self.assertEqual(len(written[0]), 2)
        self.assertTrue(written[0][1].startswith("* * * * * "))
        self.assertIn(" log codex >/dev/null 2>&1 ", written[0][1])
        self.assertTrue(written[0][1].endswith(f"{usage.CRON_MARKER}codex"))

    def test_install_schedules_claude_every_thirty_seconds(self):
        written = []
        with patch.object(usage, "cron_lines", return_value=[]), \
                patch.object(usage, "write_cron_lines", side_effect=written.append), \
                patch.object(usage, "log_usage", return_value={"lastRunAt": 1}), \
                patch.object(usage, "cli_search_path", return_value="/usr/bin"):
            usage.install("claude", self.home, "1.0")

        self.assertEqual(len(written[0]), 2)
        self.assertTrue(written[0][0].startswith("* * * * * /"))
        self.assertTrue(written[0][1].startswith("* * * * * sleep 30; "))
        self.assertTrue(all(line.endswith(f"{usage.CRON_MARKER}claude") for line in written[0]))

    def test_uninstall_keeps_other_entries(self):
        crontab = [f"* * * * * a {usage.CRON_MARKER}claude", f"* * * * * b {usage.CRON_MARKER}codex"]
        written = []
        with patch.object(usage, "cron_lines", return_value=crontab), \
                patch.object(usage, "write_cron_lines", side_effect=written.append):
            usage.uninstall("codex")

        self.assertEqual(written, [[crontab[0]]])


if __name__ == "__main__":
    unittest.main()

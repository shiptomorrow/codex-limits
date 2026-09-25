import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
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
        with patch.object(usage, "codex_search_path", return_value=str(self.home)):
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
        self.assertEqual(first["backoffUntil"], 110)
        self.assertEqual(urlopen.call_count, 1)

    def test_checks_less_often_while_mac_is_logging(self):
        self.install_fake_codex()
        usage.log_usage("codex", self.home, now=100)
        exported = usage.export("codex", self.home, 0, mac_logging_until=2000)
        self.assertEqual(exported["macLoggingUntil"], 2000)

        os.environ["FAKE_USED"] = "13"
        skipped = usage.log_usage("codex", self.home, now=160)
        self.assertEqual(skipped["lastRunAt"], 100)
        checked = usage.log_usage("codex", self.home, now=100 + usage.MAC_LOGGING_CHECK_INTERVAL - 5)
        self.assertEqual(checked["lastRunAt"], 100 + usage.MAC_LOGGING_CHECK_INTERVAL - 5)

        usage.export("codex", self.home, 0, mac_logging_until=0)
        os.environ["FAKE_USED"] = "14"
        resumed = usage.log_usage("codex", self.home, now=800)
        self.assertEqual(resumed["lastRunAt"], 800)
        self.assertEqual(len(usage.export("codex", self.home, 0)["entries"]), 3)

    def test_claude_does_not_send_expired_token(self):
        (self.home / ".claude").mkdir()
        (self.home / ".claude/.credentials.json").write_text(json.dumps({
            "claudeAiOauth": {"accessToken": "token", "expiresAt": 1000}
        }))
        with patch.object(usage.urllib.request, "urlopen") as urlopen:
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
                patch.object(usage, "codex_search_path", return_value="/usr/bin"):
            result = usage.install("codex", self.home, "1.0")

        self.assertTrue(result["installed"])
        self.assertEqual(written[0][0], "0 * * * * backup")
        self.assertEqual(len(written[0]), 2)
        self.assertTrue(written[0][1].startswith("* * * * * "))
        self.assertIn(" log codex >/dev/null 2>&1 ", written[0][1])
        self.assertTrue(written[0][1].endswith(f"{usage.CRON_MARKER}codex"))

    def test_install_schedules_claude_every_two_minutes(self):
        written = []
        with patch.object(usage, "cron_lines", return_value=[]), \
                patch.object(usage, "write_cron_lines", side_effect=written.append), \
                patch.object(usage, "log_usage", return_value={"lastRunAt": 1}):
            usage.install("claude", self.home, "1.0")

        self.assertTrue(written[0][0].startswith("*/2 * * * * "))

    def test_uninstall_keeps_other_entries(self):
        crontab = [f"* * * * * a {usage.CRON_MARKER}claude", f"* * * * * b {usage.CRON_MARKER}codex"]
        written = []
        with patch.object(usage, "cron_lines", return_value=crontab), \
                patch.object(usage, "write_cron_lines", side_effect=written.append):
            usage.uninstall("codex")

        self.assertEqual(written, [[crontab[0]]])


if __name__ == "__main__":
    unittest.main()

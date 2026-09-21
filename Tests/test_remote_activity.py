import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "remote_activity", Path(__file__).resolve().parents[1] / "Resources/remote-activity.py"
)
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)


def completion(turn_id, start, end):
    return json.dumps({
        "type": "event_msg",
        "payload": {
            "type": "task_complete", "turn_id": turn_id,
            "started_at": start, "completed_at": end,
        },
    }).encode() + b"\n"


class RemoteActivityCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.cache = self.root / "cache.json"
        self.session = self.root / "session.jsonl"
        self.other = self.root / "other.jsonl"
        self.files = [("session", self.session), ("other", self.other)]
        self.old = completion("old", 100, 200)
        self.new = completion("new", 300, 400)
        self.other.write_bytes(completion("other", 500, 600))

    def read(self):
        entries = activity.update_cache(self.cache, self.files)
        return sorted(activity.intervals(entries, 0, 1000), key=lambda item: item["start"])

    def expected(self, *pairs):
        return [
            {"start": start, "end": end, "isFastMode": False}
            for start, end in sorted((*pairs, (500, 600)))
        ]

    def test_subagent_setting_filters_cached_completed_and_active_turns(self):
        metadata = json.dumps({
            "type": "session_meta",
            "payload": {"thread_source": "subagent"},
        }).encode() + b"\n"
        self.session.write_bytes(metadata + self.old + b'\n'.join([
            json.dumps({"type": "event_msg", "payload": {
                "type": "task_started", "turn_id": "active", "started_at": 700,
            }}).encode(),
            json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:13:20Z",
                        "payload": {"type": "token_count"}}).encode(),
            b"",
        ]))
        for includes_subagents in (False, True, False):
            entries = activity.update_cache(self.cache, self.files)
            actual = sorted(activity.intervals(
                entries, 0, 1000, includes_subagents=includes_subagents,
            ), key=lambda item: item["start"])
            expected = self.expected((100, 200), (700, 800)) if includes_subagents else self.expected()
            if includes_subagents:
                for interval in expected:
                    if interval["start"] in (100, 700):
                        interval["subagentID"] = "session"
            self.assertEqual(actual, expected)

    def test_first_header_excludes_inherited_parent_turns_after_cache_appends(self):
        def metadata(source, timestamp):
            return json.dumps({"type": "session_meta", "payload": {
                "thread_source": source, "timestamp": timestamp,
            }}).encode() + b"\n"
        child_header = metadata("subagent", "1970-01-01T00:05:00.900Z")
        parent_header = metadata("user", "1970-01-01T00:01:00Z")
        # The copied parent turn overlaps the child's creation, but belongs to the parent.
        self.session.write_bytes(child_header + parent_header + completion("parent", 100, 350)
                                 + completion("child", 300, 400))
        for _ in range(2):
            entries = activity.update_cache(self.cache, self.files)
            self.assertEqual(activity.intervals(entries, 0, 1000), self.expected())
            included = activity.intervals(entries, 0, 1000, includes_subagents=True)
            child = [item for item in included if item.get("subagentID")]
            self.assertEqual(child, [{"start": 300, "end": 400, "isFastMode": False,
                                      "subagentID": "session"}])
            with self.session.open("ab") as handle:
                handle.write(parent_header)

    def test_rewrites_replace_old_events_and_preserve_other_files(self):
        scenarios = {
            "truncated": (b"", b" " * 1000 + b"\n", b""),
            "same_size": (b"", b"", b""),
            "prefix_changed": (b"", b"", b" " * 1000 + b"\n"),
            "suffix_changed": (b" " * 9000 + b"\n", b"", b" " * 1000 + b"\n"),
        }
        for name, (prefix, old_tail, new_tail) in scenarios.items():
            with self.subTest(name=name):
                self.session.write_bytes(prefix + self.old + old_tail)
                os.utime(self.session, ns=(1_000_000_000, 1_000_000_000))
                self.assertEqual(self.read(), self.expected((100, 200)))
                self.session.write_bytes(prefix + self.new + new_tail)
                self.assertEqual(self.read(), self.expected((300, 400)))
                self.assertEqual(self.read(), self.expected((300, 400)))
                with self.session.open("ab") as handle:
                    handle.write(completion("appended", 700, 800))
                self.assertEqual(self.read(), self.expected((300, 400), (700, 800)))

    def test_rebuilds_legacy_corruption(self):
        self.session.write_bytes(self.old)
        self.read()
        store = json.loads(self.cache.read_text())
        store["corruption_message"] = "session became smaller"
        self.cache.write_text(json.dumps(store))
        self.session.write_bytes(self.new)
        self.assertEqual(self.read(), self.expected((300, 400)))
        self.assertIsNone(json.loads(self.cache.read_text())["corruption_message"])
        self.assertEqual(self.read(), self.expected((300, 400)))

    def test_clears_legacy_corruption_even_when_no_files_are_selected(self):
        self.cache.write_text(json.dumps({
            "version": activity.CACHE_VERSION,
            "corruption_message": "session became smaller", "files": {},
        }))
        self.assertEqual(activity.update_cache(self.cache, []), [])
        self.assertIsNone(json.loads(self.cache.read_text())["corruption_message"])

    def test_retries_after_rebuild_read_failure(self):
        self.session.write_bytes(self.old)
        self.read()
        previous_cache = self.cache.read_bytes()
        self.session.write_bytes(b"")
        with patch.object(activity, "parse_file", side_effect=OSError("read failed")):
            with self.assertRaises(OSError):
                self.read()
        self.assertEqual(self.cache.read_bytes(), previous_cache)
        self.assertEqual(self.read(), self.expected())

    def test_append_waits_for_complete_line(self):
        self.session.write_bytes(self.old + self.new[:-1])
        self.assertEqual(self.read(), self.expected((100, 200)))
        with self.session.open("ab") as handle:
            handle.write(b"\n")
        self.assertEqual(self.read(), self.expected((100, 200), (300, 400)))
        self.assertEqual(self.read(), self.expected((100, 200), (300, 400)))

    def test_timestamp_only_change_does_not_duplicate_events(self):
        self.session.write_bytes(self.old)
        self.read()
        os.utime(self.session, ns=(1_000_000_000, 1_000_000_000))
        self.assertEqual(self.read(), self.expected((100, 200)))

    def test_interrupted_turn_stops_before_later_activity(self):
        def started(turn_id, date):
            return json.dumps({
                "type": "event_msg", "payload": {
                    "type": "task_started", "turn_id": turn_id, "started_at": date,
                },
            }).encode() + b"\n"

        def token(timestamp):
            return json.dumps({
                "timestamp": timestamp, "type": "event_msg",
                "payload": {"type": "token_count"},
            }).encode() + b"\n"

        self.session.write_bytes(started("interrupted", 100))
        self.read()
        with self.session.open("ab") as handle:
            handle.write(completion("interrupted", 100, 200).replace(
                b'task_complete', b'turn_aborted'
            ))
            handle.write(started("resumed", 700))
            handle.write(token("1970-01-01T00:13:20Z"))
        expected = self.expected((100, 200), (700, 800))
        self.assertEqual(self.read(), expected)

        self.assertEqual(self.read(), expected)

        # A cache with unchanged source files must still recover the lost abort.
        store = json.loads(self.cache.read_text())
        store["version"] = 2
        store["files"]["session"]["events"]["completions"] = []
        self.cache.write_text(json.dumps(store))
        self.assertEqual(self.read(), expected)

    def test_removes_only_approval_wait_and_preserves_execution_time(self):
        for requires_approval, output, expected in [
            (True, "Script running with cell ID 2\nWall time 31.0 seconds\nOutput:\n", [(100, 110), (14919, 15000)]),
            (False, "Script running with cell ID 2\nWall time 31.0 seconds\nOutput:\n", [(100, 15000)]),
            (True, "Unknown execution time", [(100, 15000)]),
            (True, "Script completed\nWall time 14840.0 seconds\nOutput:\n", [(100, 15000)]),
        ]:
            # Use a four-hour approval gap, while retaining a 31-second execution.
            end = 15_000
            events = activity.empty_events()
            events["completions"] = [["turn", 100, end]]
            call = {
                "type": "response_item", "timestamp": "1970-01-01T00:01:50Z",
                "payload": {"type": "custom_tool_call", "call_id": "call", "input":
                    'text(await tools.exec_command({sandbox_permissions:"require_escalated"}));'
                    if requires_approval else 'text(await tools.exec_command({cmd:"build"}));'},
            }
            result = {
                "type": "response_item", "timestamp": "1970-01-01T04:09:10Z",
                "payload": {"type": "custom_tool_call_output", "call_id": "call", "output": output},
            }
            for obj in (call, result):
                parsed = activity.parse_line(json.dumps(obj).encode())
                if parsed:
                    activity.append_events(events, parsed)
            actual = activity.intervals([{"events": events}], 0, 20_000)
            self.assertEqual([(i["start"], i["end"]) for i in actual], expected)


if __name__ == "__main__":
    unittest.main()

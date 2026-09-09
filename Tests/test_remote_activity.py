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


if __name__ == "__main__":
    unittest.main()

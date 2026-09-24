import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "remote_claude_activity",
    Path(__file__).resolve().parents[1] / "Resources/remote-claude-activity.py",
)
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)


def message(kind, seconds, content="", sidechain=False):
    timestamp = f"2026-09-24T20:{seconds // 60:02d}:{seconds % 60:02d}.000Z"
    return json.dumps({
        "type": kind,
        "timestamp": timestamp,
        "isSidechain": sidechain,
        "message": {"content": content},
    }).encode() + b"\n"


def tool_result(seconds):
    return message("user", seconds, [{"type": "tool_result", "content": "ok"}])


BASE = 1790280000.0  # 2026-09-24T20:00:00Z


class RemoteClaudeActivityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.projects = self.root / "projects"
        self.cache = self.root / "cache.json"
        self.session = self.projects / "project" / "session.jsonl"
        self.session.parent.mkdir(parents=True)

    def read(self, includes_subagents=False):
        files = activity.selected_files(0, self.projects)
        entries = activity.update_cache(self.cache, files, BASE + 3600)
        return sorted(
            (item["start"] - BASE, item["end"] - BASE, item["subagentID"])
            for item in activity.intervals(entries, 0, BASE + 3600, includes_subagents)
        )

    def test_turn_runs_from_prompt_through_last_tool_result(self):
        self.session.write_bytes(
            message("user", 0, "hello")
            + message("assistant", 30)
            + tool_result(90)
            + message("assistant", 120)
            + message("user", 300, "next")
            + message("assistant", 360)
        )
        self.assertEqual(self.read(), [(0, 120, None), (300, 360, None)])

    def test_long_wait_inside_turn_is_not_counted(self):
        self.session.write_bytes(
            message("user", 0, "hello")
            + message("assistant", 60)
            + tool_result(60 + 16 * 60)
            + message("assistant", 60 + 17 * 60)
        )
        self.assertEqual(self.read(), [(0, 60, None), (1020, 1080, None)])

    def test_subagents_are_only_included_when_requested(self):
        subagent = self.session.parent / "session" / "subagents" / "agent-a.jsonl"
        subagent.parent.mkdir(parents=True)
        self.session.write_bytes(message("user", 0, "hello") + message("assistant", 60))
        subagent.write_bytes(
            message("user", 10, "task", sidechain=True)
            + message("assistant", 200, sidechain=True)
        )
        self.assertEqual(self.read(), [(0, 60, None)])
        self.assertEqual(self.read(includes_subagents=True), [
            (0, 60, None),
            (10, 200, "claude:project/session/subagents/agent-a.jsonl"),
        ])

    def test_appended_lines_are_parsed_incrementally_and_rewrites_reset(self):
        self.session.write_bytes(message("user", 0, "hello") + message("assistant", 60))
        self.assertEqual(self.read(), [(0, 60, None)])
        with self.session.open("ab") as handle:
            handle.write(message("assistant", 120) + b'{"type":"assistant"')
        self.assertEqual(self.read(), [(0, 120, None)])

        self.session.write_bytes(message("user", 600, "rewritten") + message("assistant", 660))
        self.assertEqual(self.read(), [(600, 660, None)])


if __name__ == "__main__":
    unittest.main()

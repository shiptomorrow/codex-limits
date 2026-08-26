import base64
import datetime
import fcntl
import json
import os
import pathlib
import sys
import traceback


CACHE_VERSION = 2
GUARD_LENGTH = 4096
MAXIMUM_SESSION_FILE_SIZE = 50_000_000


def empty_events():
    return {
        "starts": [],
        "completions": [],
        "token_times": [],
        "mode_changes": [],
        "is_subagent": None,
    }


def append_events(destination, source):
    for key in ("starts", "completions", "token_times", "mode_changes"):
        destination[key].extend(source[key])
    if source["is_subagent"] is not None:
        destination["is_subagent"] = source["is_subagent"]


def timestamp_seconds(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def parse_line(line):
    is_session_metadata = b'"session_meta"' in line
    if not is_session_metadata and b'"event_msg"' not in line:
        return None
    if is_session_metadata:
        try:
            obj = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        payload = obj.get("payload")
        if obj.get("type") != "session_meta" or not isinstance(payload, dict):
            return None
        events = empty_events()
        source = payload.get("source")
        events["is_subagent"] = payload.get("thread_source") == "subagent" or (
            isinstance(source, dict) and "subagent" in source
        )
        return events

    markers = (
        b'"task_started"',
        b'"task_complete"',
        b'"token_count"',
        b'"thread_settings_applied"',
    )
    if not any(marker in line for marker in markers):
        return None
    try:
        obj = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    payload = obj.get("payload")
    if not isinstance(payload, dict):
        return None
    events = empty_events()
    event_type = payload.get("type")

    if event_type == "thread_settings_applied":
        settings = payload.get("thread_settings")
        date = timestamp_seconds(obj.get("timestamp"))
        if not isinstance(settings, dict) or not isinstance(settings.get("service_tier"), str):
            return None
        if date is None:
            return None
        events["mode_changes"].append(
            [date, settings["service_tier"] in ("fast", "priority")]
        )
    elif event_type == "task_started":
        turn_id = payload.get("turn_id")
        started_at = payload.get("started_at")
        if not isinstance(turn_id, str) or not isinstance(started_at, (int, float)):
            return None
        events["starts"].append([turn_id, float(started_at)])
    elif event_type == "task_complete":
        turn_id = payload.get("turn_id")
        started_at = payload.get("started_at")
        completed_at = payload.get("completed_at")
        if (
            not isinstance(turn_id, str)
            or not isinstance(started_at, (int, float))
            or not isinstance(completed_at, (int, float))
        ):
            return None
        events["completions"].append(
            [turn_id, float(started_at), float(completed_at)]
        )
    elif event_type == "token_count":
        date = timestamp_seconds(obj.get("timestamp"))
        if date is None:
            return None
        events["token_times"].append(date)
    else:
        return None
    return events


def parse_file(path, offset):
    events = empty_events()
    consumed = 0
    with path.open("rb") as handle:
        handle.seek(offset)
        for line in handle:
            if not line.endswith(b"\n"):
                break
            consumed += len(line)
            parsed = parse_line(line.rstrip(b"\r\n"))
            if parsed is not None:
                append_events(events, parsed)
    return events, consumed


def read_guard(path, offset, count):
    if count <= 0:
        return ""
    with path.open("rb") as handle:
        handle.seek(offset)
        return base64.b64encode(handle.read(count)).decode("ascii")


def prefix_guard(path, parsed_offset):
    return read_guard(path, 0, min(GUARD_LENGTH, parsed_offset))


def suffix_guard(path, parsed_offset):
    count = min(GUARD_LENGTH, parsed_offset)
    return read_guard(path, parsed_offset - count, count)


def selected_files(since, now, home):
    first_day = datetime.datetime.fromtimestamp(
        since - 86400, datetime.timezone.utc
    ).date()
    final_day = datetime.datetime.fromtimestamp(
        now + 86400, datetime.timezone.utc
    ).date()
    day_names = set()
    day = first_day
    while day <= final_day:
        day_names.add(day.isoformat())
        day += datetime.timedelta(days=1)

    files = {}
    archived_root = home / ".codex" / "archived_sessions"
    if archived_root.is_dir():
        for path in archived_root.iterdir():
            if not path.is_file() or path.suffix != ".jsonl":
                continue
            if not any(path.name.startswith(f"rollout-{name}T") for name in day_names):
                continue
            if path.stat().st_size <= MAXIMUM_SESSION_FILE_SIZE:
                files[path.name] = (f"archived/{path.name}", path)

    sessions_root = home / ".codex" / "sessions"
    for name in day_names:
        day = datetime.date.fromisoformat(name)
        directory = sessions_root / f"{day.year:04d}" / f"{day.month:02d}" / f"{day.day:02d}"
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if not path.is_file() or path.suffix != ".jsonl":
                continue
            if path.stat().st_size <= MAXIMUM_SESSION_FILE_SIZE:
                key = str(path.relative_to(sessions_root))
                files[path.name] = (key, path)
    return sorted(files.values(), key=lambda item: item[0])


def save_cache(cache_path, store):
    cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = cache_path.with_name(f"{cache_path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(store, handle, separators=(",", ":"))
    temporary.chmod(0o600)
    os.replace(temporary, cache_path)


def poison(cache_path, store, detail):
    store["corruption_message"] = detail
    save_cache(cache_path, store)
    raise RuntimeError(
        f"Codex changed previously parsed session data ({detail}). "
        "Delete ~/.codex/codex-limits/remote-events-v2.json to rebuild the remote cache."
    )


def update_cache(cache_path, files):
    try:
        with cache_path.open("r", encoding="utf-8") as handle:
            store = json.load(handle)
        if store.get("version") != CACHE_VERSION:
            raise ValueError("cache version changed")
    except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
        store = {"version": CACHE_VERSION, "corruption_message": None, "files": {}}

    if store.get("corruption_message"):
        raise RuntimeError(
            "Remote activity cache is marked corrupt: "
            + store["corruption_message"]
            + ". Delete ~/.codex/codex-limits/remote-events-v2.json to rebuild it."
        )

    changed = False
    for key, path in files:
        stat = path.stat()
        size = stat.st_size
        modification_time = stat.st_mtime_ns
        entry = store["files"].get(key)
        if entry is not None:
            if size < entry["observed_size"]:
                poison(cache_path, store, f"{path.name} became smaller")
            if size == entry["observed_size"]:
                if modification_time != entry["modification_time"]:
                    poison(cache_path, store, f"{path.name} changed without growing")
                continue
            parsed_offset = entry["parsed_offset"]
            if (
                prefix_guard(path, parsed_offset) != entry["prefix_guard"]
                or suffix_guard(path, parsed_offset) != entry["suffix_guard"]
            ):
                poison(cache_path, store, f"{path.name} rewrote its cached prefix")
            events, consumed = parse_file(path, parsed_offset)
            append_events(entry["events"], events)
            entry["parsed_offset"] += consumed
            entry["observed_size"] = size
            entry["modification_time"] = modification_time
            entry["prefix_guard"] = prefix_guard(path, entry["parsed_offset"])
            entry["suffix_guard"] = suffix_guard(path, entry["parsed_offset"])
        else:
            events, consumed = parse_file(path, 0)
            entry = {
                "observed_size": size,
                "modification_time": modification_time,
                "parsed_offset": consumed,
                "prefix_guard": prefix_guard(path, consumed),
                "suffix_guard": suffix_guard(path, consumed),
                "events": events,
            }
            store["files"][key] = entry
        changed = True

    if changed:
        save_cache(cache_path, store)
    return [store["files"][key] for key, _ in files]


def split_interval(start, end, changes, inherited_changes):
    changes = sorted(changes, key=lambda value: value[0])
    inherited = [change for change in inherited_changes if change[0] <= start]
    own = [change for change in changes if change[0] <= start]
    is_fast = own[-1][1] if own else inherited[-1][1] if inherited else False
    result = []
    segment_start = start
    for date, fast in changes:
        if date <= start or date >= end:
            continue
        result.append(
            {"start": segment_start, "end": date, "isFastMode": is_fast}
        )
        segment_start = date
        is_fast = fast
    result.append({"start": segment_start, "end": end, "isFastMode": is_fast})
    return result


def intervals(entries, since, now):
    entries = [entry for entry in entries if entry["events"].get("is_subagent") is not True]
    starts = {}
    completed_ids = set()
    completed = []
    all_mode_changes = []
    for index, entry in enumerate(entries):
        events = entry["events"]
        all_mode_changes.extend(events["mode_changes"])
        for turn_id, date in events["starts"]:
            starts[turn_id] = (date, index)
        for turn_id, start, end in events["completions"]:
            completed_ids.add(turn_id)
            completed.append((start, end, index))

    result = []
    for start, end, index in completed:
        result.extend(
            split_interval(
                start,
                end,
                entries[index]["events"]["mode_changes"],
                all_mode_changes,
            )
        )
    for turn_id, (start, index) in starts.items():
        if turn_id in completed_ids:
            continue
        token_times = [
            value
            for value in entries[index]["events"]["token_times"]
            if value >= start and value <= now
        ]
        end = max(token_times) if token_times else start
        if end > start:
            result.extend(
                split_interval(
                    start,
                    end,
                    entries[index]["events"]["mode_changes"],
                    all_mode_changes,
                )
            )
    return [item for item in result if item["end"] >= since and item["start"] <= now]


def main():
    since = float(sys.argv[1])
    now = float(sys.argv[2])
    home = pathlib.Path.home()
    cache_directory = home / ".codex" / "codex-limits"
    cache_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache_path = cache_directory / "remote-events-v2.json"
    lock_path = cache_directory / "remote-events-v2.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files = selected_files(since, now, home)
        entries = update_cache(cache_path, files)
        json.dump(
            {"version": 1, "intervals": intervals(entries, since, now)},
            sys.stdout,
            separators=(",", ":"),
        )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

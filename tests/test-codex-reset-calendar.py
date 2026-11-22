"""Exercise the calendar updater through its CLI with fake query and DAV commands."""

from datetime import UTC, datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from icalendar import Calendar, Event


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "home/scripts/sync-codex-resets-calendar.py"


class CalendarTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calendar = self.root / "calendars/fastmail/collection-id"
        self.calendar.mkdir(parents=True)
        (self.calendar / "displayname").write_text("Miscellaneous")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.command("query-codex-resets", '''
import os, pathlib, sys
assert sys.argv[1:] == ["--json"]
print(pathlib.Path(os.environ["QUERY_RESULT"]).read_text())
sys.exit(int(os.environ.get("QUERY_EXIT", "0")))
''')
        self.command("vdirsyncer", '''
import os, pathlib, sys
assert sys.argv[1:] == ["sync", "calendar_fastmail/collection-id"]
assert os.environ.get("SECRETSPEC_REASON")
with pathlib.Path(os.environ["SYNC_LOG"]).open("a") as log:
    log.write("sync\\n")
sys.exit(int(os.environ.get("SYNC_EXIT", "0")))
''')
        self.result = self.root / "query.json"
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "XDG_STATE_HOME": str(self.root / "state"),
            "QUERY_RESULT": str(self.result),
            "SYNC_LOG": str(self.root / "sync.log"),
        }
        self.result.write_text(json.dumps(["2026-10-29T10:00:00Z", "2026-10-03T10:00:00Z"]))

    def command(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{body}")
        path.chmod(0o700)

    def run_script(self, *arguments, success=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--calendar", "Miscellaneous",
             "--calendar-root", str(self.root / "calendars"), *arguments],
            env=self.env, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def files(self):
        return {path.name: path.read_bytes() for path in self.calendar.glob("*.ics")}

    def test_idempotent_duplicates_and_dst(self):
        self.result.write_text(json.dumps([
            "2026-10-29T10:00:00Z", "2026-10-29T11:00:00+01:00",
            "2026-10-29T10:00:00.123Z",
            "2026-10-03T10:00:00Z", "2026-10-03T12:00:00+02:00",
        ]))
        self.run_script()
        first = self.files()
        self.assertEqual(len(first), 2)
        times = []
        for data in first.values():
            event = Calendar.from_ical(data).walk("VEVENT")[0]
            times.append(event.decoded("DTSTART"))
            self.assertEqual(str(event["SUMMARY"]), "Codex reset credit expires")
            self.assertEqual((event.decoded("DTEND") - event.decoded("DTSTART")).total_seconds(), 300)
            self.assertEqual(str(event["TRANSP"]), "TRANSPARENT")
        self.assertEqual(sorted(times), [datetime(2026, 10, 3, 10, tzinfo=UTC), datetime(2026, 10, 29, 10, tzinfo=UTC)])
        self.run_script()
        self.assertEqual(self.files(), first)
        self.assertEqual((self.root / "sync.log").read_text().splitlines(), ["sync"] * 4)

    def test_renamed_remote_file_and_duplicate_uid(self):
        self.run_script()
        path = next(self.calendar.glob("*.ics"))
        data = path.read_bytes()
        path.rename(self.calendar / "remote-name.ics")
        (self.calendar / "duplicate.ics").write_bytes(data)
        self.run_script()
        self.assertEqual(len(self.files()), 2)
        uids = [str(Calendar.from_ical(data).walk("VEVENT")[0]["UID"]) for data in self.files().values()]
        self.assertEqual(len(uids), len(set(uids)))

    def test_stale_entries_and_manual_events(self):
        self.run_script()
        calendar = Calendar()
        calendar.add("VERSION", "2.0")
        event = Event()
        event.add("UID", "manual-event")
        event.add("DTSTART", datetime(2026, 10, 3, 12, tzinfo=UTC))
        calendar.add_component(event)
        manual = calendar.to_ical()
        (self.calendar / "manual.ics").write_bytes(manual)
        self.result.write_text('["2026-11-01T10:00:00Z"]')
        self.run_script()
        self.assertEqual(len(self.files()), 2)
        self.assertEqual((self.calendar / "manual.ics").read_bytes(), manual)
        self.result.write_text("[]")
        self.run_script()
        self.assertEqual(self.files(), {"manual.ics": manual})

    def test_failures_preserve_events(self):
        self.run_script()
        before = self.files()
        for payload in ['{}', '["not-a-date"]', '["2026-10-29T10:00:00"]', '[42]', 'not json']:
            with self.subTest(payload=payload):
                self.result.write_text(payload)
                self.run_script(success=False)
                self.assertEqual(self.files(), before)
        self.result.write_text("[]")
        self.env["QUERY_EXIT"] = "1"
        self.run_script(success=False)
        self.assertEqual(self.files(), before)
        del self.env["QUERY_EXIT"]
        self.env["SYNC_EXIT"] = "1"
        self.run_script(success=False)
        self.assertEqual(self.files(), before)

    def test_title_update_is_idempotent(self):
        self.run_script()
        self.run_script("--title", "Codex reminder")
        changed = self.files()
        for data in changed.values():
            event = Calendar.from_ical(data).walk("VEVENT")[0]
            self.assertEqual(str(event["SUMMARY"]), "Codex reminder")
            self.assertEqual(int(event["SEQUENCE"]), 1)
        self.run_script("--title", "Codex reminder")
        self.assertEqual(self.files(), changed)

    def test_local_only_and_ambiguous_calendar(self):
        self.run_script("--no-sync")
        self.assertFalse((self.root / "sync.log").exists())
        before = self.files()
        other = self.calendar.parent / "other-id"
        other.mkdir()
        (other / "displayname").write_text("Miscellaneous")
        self.run_script(success=False)
        self.assertEqual(self.files(), before)
        self.run_script("--calendar", "collection-id", "--no-sync")


class QueryTest(unittest.TestCase):
    def test_json_table_and_invalid_backend_response(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "auth.json").write_text('{"tokens":{"access_token":"fixture-token"}}')
            response = root / "response.json"
            curl = root / "curl"
            curl.write_text(f"#!{sys.executable}\nimport os,pathlib,sys\nsys.stdin.read()\nprint(pathlib.Path(os.environ['RESPONSE']).read_text())\n")
            curl.chmod(0o700)
            env = os.environ | {"CODEX_HOME": str(root), "RESPONSE": str(response), "PATH": f"{root}:{os.environ['PATH']}"}
            command = ["bash", "-euo", "pipefail", str(REPO / "home/scripts/query-codex-resets")]
            response.write_text('{"credits":[{"status":"available","expires_at":"2026-10-29T10:00:00Z"},{"status":"used"}]}')
            result = subprocess.run([*command, "--json"], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), ["2026-10-29T10:00:00Z"])
            result = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
            self.assertIn("Original (API)", result.stdout)
            self.assertIn("2026-10-29T10:00:00Z", result.stdout)
            response.write_text('{"credits":[]}')
            result = subprocess.run([*command, "--json"], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [])
            for payload in ['{}', '{"credits":[{}]}', '{"credits":[{"status":"available"}]}']:
                response.write_text(payload)
                result = subprocess.run([*command, "--json"], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, payload)


if __name__ == "__main__":
    unittest.main()

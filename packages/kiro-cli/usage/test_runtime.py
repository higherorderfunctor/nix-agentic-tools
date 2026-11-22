"""Exercise launch behavior, exit cards, and CLI history refreshes against private fixture stores."""
# cspell:words preexec TIOCSCTTY
import base64
from concurrent.futures import ThreadPoolExecutor
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import capture
from capture import Collector, lock_beside, open_database
import disk_index
from mitm_addon import UsageCapture
import query
import report
import runtime

def _measured_value_options(variable):
    """Read a comma-separated option table exported by the offline check."""
    measured = os.environ.get(variable)
    if not measured:
        raise RuntimeError(
            f"{variable} is unset. Export the measured list as shown in packages/kiro-cli/usage/README.md."
        )
    return measured


CHAT_VALUE_OPTIONS_ARG = "--chat-value-options=" + _measured_value_options("KIRO_CHAT_VALUE_OPTIONS")
LAUNCH_VALUE_OPTIONS = tuple(_measured_value_options("KIRO_LAUNCH_VALUE_OPTIONS").split(","))


def supervised_fixture_environment():
    """Give supervised subprocess fixtures a fresh launch environment."""
    launch_settings = {runtime.INVOCATION, runtime.LAUNCH_HANDOFF, runtime.OUTERMOST_INVOCATION,
                       *runtime.PROXY_NAMES}
    return {name: value for name, value in os.environ.items() if name not in launch_settings}


class HistoryRefreshTests(unittest.TestCase):
    """Exercise history on a private store through CLI subprocesses or in-process hooks, and simulate tracked exits."""

    def setUp(self):
        """Seed two captures in a fixture home shared by the CLI and simulated exits."""
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(directory)
        self.state = self.root / "state"
        self.database = self.state / "usage.sqlite3"
        self.sessions = self.root / ".kiro/sessions"
        self.enterContext(patch.dict(os.environ, HOME=directory, clear=True))
        collector = Collector(self.database)
        request = b'{"metadata":{"kiro:conversation_id":"sess_root"}}'
        for invocation in ("a" * 32, "b" * 32):
            collector.finish(collector.begin({"invocation": invocation}, request))
        collector.close()

    def write_session(self, name="sess_root", **metadata):
        """Write session metadata and append one usage turn for a later CLI refresh or simulated exit."""
        session = self.sessions / "workspace" / name
        session.mkdir(parents=True, exist_ok=True)
        (session / "session.json").write_text(json.dumps(metadata))
        with (session / "messages.jsonl").open("a") as messages:
            messages.write('{"payload":{"type":"usage_summary","promptTurnSummaries":[{"usage":1.5,"unit":"credit"}]}}\n')
        return session

    def index(self):
        """Seed a full index in-process before running a CLI refresh or simulating an exit."""
        with contextlib.closing(open_database(self.database)) as db:
            disk_index.index_tree(db, self.sessions)

    def run_cli(self, *arguments):
        """Run the real CLI as a subprocess against the fixture and return its output."""
        return subprocess.run([sys.executable, runtime.__file__, "cli", "--state-dir", str(self.state),
                               "--port", "19001", "--warn-bytes", str(1 << 30),
                               "--launch-value-options=" + ",".join(LAUNCH_VALUE_OPTIONS), "--", *arguments],
                              capture_output=True, text=True, check=True)

    def run_exec(self, *arguments, invocation="a" * 32):
        """Simulate the tracked child's exit and return stderr from the real exit handling."""
        with (patch.object(runtime, "launch_environment", return_value={}),
              patch.object(runtime, "wait_command", return_value=23),
              patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex=invocation)),
              patch.object(runtime, "SETTLE_TIMEOUT", 0),
              contextlib.redirect_stderr(io.StringIO()) as output):
            self.assertEqual(runtime.exec_command(self.state, 19001, 1 << 30, ["kiro-cli", *arguments],
                                                  launch_value_options=LAUNCH_VALUE_OPTIONS), 23)
        return output.getvalue()

    def test_exit_does_no_disk_index_work(self):
        """A simulated tracked exit renders the capture card without probing or writing the disk index."""
        self.write_session()
        with (patch.object(os, "scandir", wraps=os.scandir) as scandir,
              patch.object(os, "stat", wraps=os.stat) as file_stat,
              patch.object(capture, "lock_beside", wraps=capture.lock_beside) as lock,
              patch.object(disk_index, "lock_beside", wraps=disk_index.lock_beside) as index_lock,
              patch.object(disk_index, "open_database", wraps=disk_index.open_database) as writer,
              patch.object(disk_index, "index_tree", wraps=disk_index.index_tree) as index):
            output = self.run_exec("chat")
            self.assertIn("Kiro usage · sess_root · this run · 1 request", output)
            scandir.assert_not_called()
            index_lock.assert_not_called()
            writer.assert_not_called()
            self.assertEqual((index.call_count, lock.call_count,
                              [str(call.args[0]) for call in file_stat.call_args_list
                               if str(call.args[0]).startswith(str(self.sessions.parent))]), (0, 0, []))

    def test_session_refreshes_changed_root_and_new_descendant(self):
        """A session tree read includes appended root turns and newly linked children."""
        self.write_session()
        self.index()
        self.write_session()
        self.write_session("sess_child", parentSessionId="root")
        result = json.loads(self.run_cli("session", "sess_root", "--scope", "tree", "--json").stdout)
        self.assertEqual((result["sessions"], result["disk"]["turns"]), (["sess_child", "sess_root"], 3))

    def test_report_refreshes_changed_root_and_new_descendant_once_for_all_ids(self):
        """A multi-session report validates all IDs before refreshing their trees together."""
        self.write_session()
        self.index()
        self.write_session()
        self.write_session("sess_child", parentSessionId="root")
        self.write_session("sess_second")
        old_child = self.write_session("sess_old_child", parentSessionId="second")
        for path in (old_child.parent, *old_child.iterdir()):
            os.utime(path, ns=(1, 1))
        invalid = ["report", "--session", "sess_root", "--session", "../bad"]
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_cli(*invalid)
        self.assertEqual(error.exception.stderr, "cannot query calibration database: --session must be a sess_UUID identifier\n")
        self.assertFalse(Path(f"{self.database}{disk_index.INDEX_LOCK}").exists())
        arguments = ["report", "--session", "sess_root", "--session", "sess_second", "--json"]
        with (patch.object(os, "execv") as execute,
              patch.object(disk_index, "index_tree", wraps=disk_index.index_tree) as index,
              contextlib.redirect_stdout(io.StringIO()) as output):
            runtime.cli(self.state, arguments, 19001, 1 << 30)
            with patch.object(sys, "argv", execute.call_args.args[1][1:]):
                report.main()
        reports = json.loads(output.getvalue())
        self.assertEqual([(item["sessions"], item["disk"]["turns"]) for item in reports],
                         [(["sess_child", "sess_root"], 3), (["sess_old_child", "sess_second"], 2)])
        index.assert_called_once()

    def test_report_releases_snapshot_before_output(self):
        """Check that named reads share a snapshot and both report shapes release it before JSON output."""
        self.write_session()
        self.write_session("sess_second")
        history_reader = query.history_reader
        read_session = query.query

        @contextlib.contextmanager
        def observe_reader(*args, **kwargs):
            """Expose the real reader so serialization can check its lifetime."""
            with history_reader(*args, **kwargs) as db:
                readers.append(db)
                yield db

        def serialize(*args, **kwargs):
            """Refuse serialization if the report still holds a read transaction."""
            try:
                self.assertFalse(readers[-1].in_transaction, "report is serializing inside its read snapshot")
            except sqlite3.ProgrammingError:
                pass
            return json.dumps(*args, **kwargs)

        def read_then_commit(db, session, *args):
            """Commit a capture for the second ID after the first query has read its results."""
            result = read_session(db, session, *args)
            if session == "sess_root":
                with contextlib.closing(Collector(self.database)) as collector:
                    request = b'{"metadata":{"kiro:conversation_id":"sess_second"}}'
                    collector.finish(collector.begin({"invocation": "c" * 32}, request))
            return result

        for sessions in ([], ["--session", "sess_root", "--session", "sess_second"]):
            with self.subTest(sessions=sessions):
                readers = []
                arguments = ["report.py", "--db", str(self.database), "--refresh-history", "--json", *sessions]
                with (patch.object(sys, "argv", arguments), patch.object(query, "history_reader", observe_reader),
                      patch.object(query, "query", read_then_commit),
                      patch.object(report, "json", SimpleNamespace(dumps=serialize)),
                      contextlib.redirect_stdout(io.StringIO()) as output):
                    report.main()
                result = json.loads(output.getvalue())
                if sessions:
                    self.assertEqual([(item["session"], item["captures"]["observations"]) for item in result],
                                     [("sess_root", 2), ("sess_second", 0)])
                    following = json.loads(self.run_cli("report", *sessions, "--json").stdout)
                    self.assertEqual([(item["session"], item["captures"]["observations"]) for item in following],
                                     [("sess_root", 2), ("sess_second", 1)])
                else:
                    self.assertIn("captures", result)

    def test_history_omits_unrepresentable_metadata_and_keeps_readable_sibling(self):
        """Report the readable sibling's turn and the omission for an unrepresentable metadata number."""
        self.write_session("sess_bad", parentSessionId="sess_root", contextWindowTokens=10**400)
        self.write_session("sess_good", parentSessionId="sess_root")
        try:
            result = self.run_cli("report", "--session", "sess_root", "--json")
        except subprocess.CalledProcessError as error:
            self.fail(error.stderr)
        self.assertEqual(result.stderr, "")
        tree, = json.loads(result.stdout)
        self.assertEqual((tree["sessions"], tree["disk"]["turns"], tree["disk"]["metadata_omitted_sessions"]),
                         (["sess_good", "sess_root"], 1, 1))
        with contextlib.closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute("SELECT reason FROM disk_session_omissions").fetchall(),
                             [("invalid_session_metadata",)])

    def test_history_keeps_unrelated_tree_when_child_metadata_is_malformed(self):
        """Read one tree after another tree's metadata breaks, then check the other tree's cached report."""
        self.write_session("sess_a")
        self.write_session("sess_b")
        child = self.write_session("sess_child", parentSessionId="sess_b")
        initial, = json.loads(self.run_cli("report", "--session", "sess_b", "--json").stdout)
        self.assertEqual((initial["sessions"], initial["disk"]["turns"]), (["sess_b", "sess_child"], 2))
        (child / "session.json").write_text("{")

        result = self.run_cli("session", "sess_a", "--json")
        self.assertEqual(result.stderr, "")
        tree = json.loads(result.stdout)
        self.assertEqual((tree["sessions"], tree["disk"]["turns"], tree["disk"]["metadata_omitted_sessions"]),
                         (["sess_a"], 1, 1))

        held = lock_beside(self.database, disk_index.INDEX_LOCK)
        try:
            result = self.run_cli("report", "--session", "sess_b", "--json")
        finally:
            os.close(held)
        self.assertIn("full Kiro session index is running", result.stderr)
        tree, = json.loads(result.stdout)
        self.assertEqual((tree["sessions"], tree["disk"]["turns"], tree["disk"]["metrics"]["credits"]["observed_sum"]),
                         (["sess_b", "sess_child"], 2, 3.0))

    def test_concurrent_history_writers_serialize_checkpoints_while_collector_commits(self):
        """Run two session CLI entry points in threads so the first can pause after reading its checkpoint."""
        session = self.write_session()
        self.index()
        self.write_session()
        paused, release, second_ready = (threading.Event() for _ in range(3))
        fingerprints = disk_index.fingerprints

        def pause_after_checkpoint(stream, offset):
            """Pause the first command's fingerprint immediately after its checkpoint SELECT."""
            if threading.get_ident() == first_thread and not paused.is_set():
                paused.set()
                self.assertTrue(release.wait(5), "first history command never released")
            return fingerprints(stream, offset)

        def observe_history_lock(database, suffix, **options):
            """Signal when the second command reaches the held history lock."""
            if suffix == disk_index.HISTORY_LOCK and threading.get_ident() != first_thread:
                with self.assertRaises(BlockingIOError):
                    lock_beside(database, suffix)
                second_ready.set()
            return lock_beside(database, suffix, **options)

        def first_command():
            """Run the same CLI entry point as the second command, with the checkpoint hook enabled."""
            nonlocal first_thread
            first_thread = threading.get_ident()
            query.main()

        first_thread = None
        arguments = ["query.py", "--db", str(self.database), "--refresh-history", "--session", "sess_root", "--json"]
        with (patch.object(sys, "argv", arguments), patch.object(disk_index, "fingerprints", pause_after_checkpoint),
              patch.object(disk_index, "lock_beside", observe_history_lock),
              patch.object(query, "print", create=True) as output, contextlib.redirect_stderr(io.StringIO()) as warnings,
              ThreadPoolExecutor(max_workers=2) as commands):
            first = commands.submit(first_command)
            try:
                self.assertTrue(paused.wait(5), "first history command never read its checkpoint")
                second = commands.submit(query.main)
                second.add_done_callback(lambda _: second_ready.set())
                self.assertTrue(second_ready.wait(5), "second history command never reached the history lock")
                collector = Collector(self.database)
                ident = collector.begin({"invocation": "c" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_root"}}')
                collector.finish(ident)
                collector.close()
                with contextlib.closing(sqlite3.connect(self.database)) as db:
                    self.assertEqual(db.execute("SELECT state FROM captures WHERE id=?", (ident,)).fetchone(),
                                     ("incomplete",))
            finally:
                release.set()
            first.result(timeout=5)
            second.result(timeout=5)
        self.assertEqual(warnings.getvalue(), "")
        self.assertEqual([json.loads(call.args[0])["disk"]["turns"] for call in output.call_args_list], [2, 2])
        with contextlib.closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM disk_records WHERE source_path=?",
                                        (str(session / "messages.jsonl"),)).fetchone(), (2,))

    def test_full_index_lock_warns_once_and_preserves_indexed_facts(self):
        self.write_session()
        self.index()
        self.write_session()
        held = lock_beside(self.database, disk_index.INDEX_LOCK)
        try:
            result = self.run_cli("report", "--session", "sess_root", "--json")
        finally:
            os.close(held)
        self.assertEqual(json.loads(result.stdout)[0]["disk"]["turns"], 1)
        self.assertEqual(result.stderr.count("Warning:"), 1)
        self.assertIn("full Kiro session index is running", result.stderr)

    def test_history_handles_missing_tree_and_read_only_cache(self):
        result = self.run_cli("session", "sess_root", "--json")
        self.assertEqual(result.stderr, "")
        self.assertFalse(json.loads(result.stdout)["disk"]["available"])
        self.assertFalse(Path(f"{self.database}{disk_index.INDEX_LOCK}").exists())
        self.write_session()
        self.index()
        self.write_session()
        with contextlib.closing(sqlite3.connect(self.database)) as db:
            capture_id = db.execute("SELECT id FROM captures LIMIT 1").fetchone()[0]
        for arguments, stderr in (
            (("report", "--json"), ""),
            (("list", "--json"), ""),
            (("unpack", capture_id, "request"), "warning: unpacking incomplete evidence\n"),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_cli(*arguments).stderr, stderr)
        self.assertFalse(Path(f"{self.database}{disk_index.INDEX_LOCK}").exists())
        self.database.chmod(0o400)
        result = self.run_cli("session", "sess_root", "--json")
        self.assertEqual(json.loads(result.stdout)["disk"]["turns"], 1)
        self.assertEqual(result.stderr.count("Warning:"), 1)
        self.assertIn("could not refresh Kiro session history", result.stderr)

    def test_no_call_resume_refreshes_only_when_requested(self):
        session = self.write_session()
        self.index()
        self.write_session()
        os.utime(session.parent, ns=(1, 1))
        output = self.run_exec("chat", "--resume-id=root", invocation="c" * 32)
        self.assertIn("no calls were captured this run", output)
        with contextlib.closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 1)
        result = json.loads(self.run_cli("session", "sess_root", "--json").stdout)
        self.assertEqual(result["disk"]["turns"], 2)

    def test_history_skips_a_directory_entry_that_cannot_be_classified(self):
        """Keep indexing the healthy sibling after a failed is_dir."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            workspace = root / ".kiro/sessions/workspace"
            bad, good = workspace / "sess_alpha", workspace / "sess_beta"
            Collector(database).close()
            for session in (bad, good):
                session.mkdir(parents=True)
                (session / "session.json").write_text('{"parentSessionId":"sess_root"}')
            (good / "messages.jsonl").write_text(
                '{"payload":{"type":"usage_summary","promptTurnSummaries":[{"usage":1.5,"unit":"credit"}]}}\n'
            )
            scandir = os.scandir

            def deny_classification(*_, **_options):
                """Stand in for DirEntry.is_dir on the bad entry: always raise."""
                raise OSError("private fixture details")

            @contextlib.contextmanager
            def scan_entries(path):
                """Wrap os.scandir, replacing only the bad entry with one whose is_dir raises."""
                with scandir(path) as entries:
                    yield (
                        SimpleNamespace(name=entry.name, path=entry.path, is_dir=deny_classification)
                        if entry.path == str(bad) else entry
                        for entry in entries
                    )

            arguments = ["query.py", "--db", str(database), "--refresh-history", "--session", "sess_root",
                         "--scope", "tree", "--json"]
            with (patch.object(os, "scandir", scan_entries), patch.object(sys, "argv", arguments),
                  contextlib.redirect_stderr(io.StringIO()) as warnings,
                  contextlib.redirect_stdout(io.StringIO()) as output):
                query.main()
            result = json.loads(output.getvalue())
            self.assertEqual((result["sessions"], result["disk"]["turns"], result["disk"]["metrics"]["credits"]["observed_sum"]),
                             (["sess_beta", "sess_root"], 1, 1.5))
            with contextlib.closing(sqlite3.connect(database)) as db:
                self.assertEqual(db.execute("SELECT path FROM disk_sessions").fetchall(), [(str(good),)])
            self.assertEqual(warnings.getvalue(),
                             f"Warning: could not read Kiro session {bad}; disk observations may be stale.\n")

    def test_history_skips_a_workspace_that_cannot_be_listed(self):
        """Keep the healthy workspace and any entries already listed when another workspace's listing fails."""
        cases = (
            # Fails if the workspace error escapes the pass.
            ("listing refused", False, ["workspace/sess_beta"]),
            # Fails if the listing is materialized before use, which discards sess_alpha.
            ("listing fails after one entry", True, ["broken/sess_alpha", "workspace/sess_beta"]),
        )
        for label, after_first, expected in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as directory, \
                    patch.dict(os.environ, {"HOME": directory}, clear=True):
                root = Path(directory)
                state = root / "state"
                database = state / "usage.sqlite3"
                sessions = root / ".kiro/sessions"
                broken = sessions / "broken"
                Collector(database).close()
                for name in ("broken/sess_alpha", "broken/sess_gamma", "workspace/sess_beta"):
                    (sessions / name).mkdir(parents=True)
                    (sessions / name / "session.json").write_text('{"parentSessionId":"sess_root"}')
                scandir = os.scandir

                @contextlib.contextmanager
                def scan_or_fail(path):
                    """Wrap os.scandir; for the broken workspace, refuse or fail after yielding sess_alpha."""
                    if str(path) != str(broken):
                        with scandir(path) as entries:
                            yield entries
                        return
                    if not after_first:
                        raise PermissionError("private fixture details")
                    with scandir(path) as entries:
                        first = next(entry for entry in entries if entry.name == "sess_alpha")

                        def fail_after_first():
                            yield first
                            raise PermissionError("private fixture details")

                        yield fail_after_first()

                with patch.object(os, "scandir", scan_or_fail), contextlib.redirect_stderr(io.StringIO()) as output:
                    disk_index.refresh_history(database, ("sess_root",))
                with contextlib.closing(sqlite3.connect(database)) as db:
                    self.assertEqual(sorted(row[0] for row in db.execute("SELECT path FROM disk_sessions")),
                                     [str(sessions / name) for name in expected])
                self.assertEqual(output.getvalue(),
                                 f"Warning: could not read Kiro workspace {broken}; disk observations may be stale.\n")


class SummaryTests(unittest.TestCase):
    def test_external_runs_on_last_card(self):
        """Group nested processes by effective root and report their usage only on the last own card."""
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            outer = "a" * 32
            collector = Collector(state / "usage.sqlite3")
            self.addCleanup(collector.close)

            def record(process, family, model, conversation, root, credits, request_id, usage, **response_fields):
                """Record a fixture request and its terminal Responses event through the collector."""
                metadata = {key: value for key, value in (
                    ("kiro:conversation_id", conversation), ("kiro:root_conversation_id", root),
                ) if value is not None}
                ident = collector.begin({"invocation": process * 32, "outermost_invocation": family * 32},
                                        json.dumps({"model": model, "metadata": metadata}).encode())
                collector.headers(ident, {"content_type": "text/event-stream", "upstream_request_id": request_id})
                terminal = {"type": "response.completed", "response": {
                    **response_fields, "usage": {**usage, "kiro:credits": {"unit": "credit", "value": credits}},
                }}
                collector.chunk(ident, b"data: " + json.dumps(terminal).encode() + b"\n\n")
                collector.finish(ident)

            for process, family, model, conversation, root, credits, request_id in (
                ("a", "a", "auto", "sess_first", None, 1, "own-first"),
                ("a", "a", "auto", "sess_second", None, 2, "own-second"),
                ("b", "a", "auto", "second", "sess_second", 3, "shared"),
                ("c", "a", "auto", "sess_second", "second", 4, "repeat"),
                ("d", "a", "opus", "sess_nested", None, 5, "shared"),
                ("b", "a", "opus", "sess_nested", "second", 6, "delegate"),
                ("d", "a", "auto", None, "nested", 7, "unknown"),
                ("d", "a", "auto", None, None, 100, "unidentified"),
                ("e", "e", "auto", "sess_second", "sess_nested", 100, "foreign"),
            ):
                usage = {"input_tokens": 20 if model == "opus" else 10, "output_tokens": 1,
                         "input_tokens_details": {"cached_tokens": min(credits, 10)}}
                record(process, family, model, conversation, root, credits, request_id, usage)
            model = "claude-haiku-4.5"
            record("d", "a", model, "sess_nested", None, .0003, "estimated",
                   {"kiro:context_usage_percentage": .05},
                   output=[{"type": "message", "content": [{"type": "output_text", "text": "pong"}]}])
            record("d", "a", model, "sess_nested", None, 1, "unpaired",
                   {"input_tokens": 100, "output_tokens": 2})
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(state, outer, 1 << 30)

        text = output.getvalue()
        self.assertEqual(text.count("External runs"), 1)
        first, last = text.split("Kiro usage · ")[1:]
        self.assertTrue(first.startswith("sess_first · this run · 1 request · 1.00 credits\n"))
        self.assertTrue(last.startswith("sess_second · this run · 1 request · 2.00 credits\n"))
        own, external = last.split("\nExternal runs\n")
        self.assertEqual(first.rstrip().splitlines()[-1].split(), ["Total", "1", "1.00", "10", "1", "1", "~10%"])
        self.assertEqual(own.rstrip().splitlines()[-1].split(), ["Total", "1", "2.00", "10", "1", "2", "~20%"])
        count, blank, header, *lines = external.splitlines()
        self.assertEqual((count, blank, header.split()),
                         ("2 sessions", "", ["Model", "Requests", "Credits", "In", "Out", "Cached", "Cache", "hit"]))
        expected_rows = [
            ["auto", "3", "14.00", "30", "3", "14", "~47%"],
            ["opus", "2", "11.00", "40", "2", "11", "~28%"],
            ["claude-haiku-4.5", "2", "1.00", "~199", "~3", "~68", "~69%"],
            ["Main", "5", "13.00", "~239", "~6", "~80", "~58%"],
            ["Sub/WF", "1", "6.00", "20", "1", "6", "~30%"],
            ["Unknown", "1", "7.00", "10", "1", "7", "~70%"],
            ["Total", "7", "26.00", "~269", "~8", "~93", "~55%"],
        ]
        labels = [row[0] for row in expected_rows]
        rows = [cells for line in lines if (cells := line.split()) and cells[0] in labels]
        self.assertEqual([row[0] for row in rows], labels)
        for actual, expected in zip(rows, expected_rows):
            with self.subTest(row=expected[0]):
                self.assertEqual(actual, expected)
        self.assertTrue(external.endswith("⚠ 1 duplicate request ID; calls with no conversation identity excluded\n"))
        self.assertEqual(text.count("calls with no conversation identity excluded"), 1)
        self.assertEqual(text.count("duplicate request ID"), 1)

    def test_exact_sessions_and_unknown_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            for invocation, session in (("a" * 32, "sess_selected"), ("b" * 32, "sess_other"), ("a" * 32, None)):
                request = {"model": "synthetic", "metadata": {"kiro:conversation_id": session}}
                ident = collector.begin({"invocation": invocation}, json.dumps(request).encode())
                collector.finish(ident)
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertIn("Kiro usage · sess_selected · this run · 1 request", output.getvalue())
            self.assertNotIn("sess_other", output.getvalue())
            self.assertIn("\n⚠ credits unknown for 1/1 request; 1 incomplete; tokens missing for 1; calls with no conversation identity excluded\n", output.getvalue())

    def test_own_cards_follow_first_capture(self):
        """Exit cards follow capture start and ID order and count only their own process's requests."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outer = "a" * 32
            own = {"invocation": outer, "outermost_invocation": outer}
            external = {"invocation": "b" * 32, "outermost_invocation": outer}
            foreign = {"invocation": "c" * 32, "outermost_invocation": "c" * 32}
            for label, a_start, a_id, z_id in (
                ("start time", 20, "1", "2"),
                ("capture ID tie break", 10, "2", "1"),
            ):
                with self.subTest(label):
                    state = root / label
                    collector = Collector(state / "usage.sqlite3")
                    self.addCleanup(collector.close)
                    for start, ident, markers, conversation, ancestor in (
                        (a_start, a_id, own, "sess_a-root-001", None),
                        (30, "3", own, "sess_z-root-001", None),
                        (40, "4", own, "sess_delegate", "z-root-001"),
                        (10, z_id, {"invocation": outer}, "z-root-001", None),
                        (5, "5", foreign, "sess_a-root-001", None),
                        (4, "6", external, "sess_a-root-001", None),
                        (6, "7", external, "sess_external", None),
                    ):
                        metadata = {"kiro:conversation_id": conversation}
                        if ancestor:
                            metadata["kiro:root_conversation_id"] = ancestor
                        request = json.dumps({"model": "auto", "metadata": metadata}).encode()
                        with (patch.object(capture.time, "time_ns", return_value=start),
                              patch.object(capture.uuid, "uuid4", return_value=SimpleNamespace(hex=ident * 32))):
                            collector.finish(collector.begin(dict(markers), request))
                    collector.close()
                    with contextlib.redirect_stderr(io.StringIO()) as output:
                        runtime.invocation_summary(state, outer, 1 << 30)
                    cards = output.getvalue().split("Kiro usage · ")[1:]
                    self.assertEqual([card.split(" · — credits")[0] for card in cards], [
                        "sess_z-root-0 · this run · 3 requests", "sess_a-root-0 · this run · 1 request",
                    ])
                    self.assertRegex(cards[0], r"Main\s+2\s.*\n.*Sub/WF\s+1\s")
                    self.assertRegex(cards[1], r"Main\s+1\s.*\n.*Sub/WF\s+0\s")

    def test_single_root_exit_card_matches_parent_stderr(self):
        """Check the entire stderr card for one root against the parent revision's output."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            invocation = "a" * 32
            collector = Collector(root / "usage.sqlite3")
            request = b'{"model":"auto","metadata":{"kiro:conversation_id":"sess_root"}}'
            collector.finish(collector.begin({"invocation": invocation, "outermost_invocation": invocation}, request))
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, invocation, 1 << 30)
            # Captured with this fixture using runtime.py and query.py from 98a58dcc.
            self.assertEqual(output.getvalue(), (
                "\nKiro usage · sess_root · this run · 1 request · — credits\n"
                "\n"
                "Model         Requests  Credits  In  Out  Cached  Cache hit\n"
                "auto                 1        —   —    —       —          —\n"
                "\n"
                "Conversation  Requests  Credits  In  Out  Cached  Cache hit\n"
                "Main                 1        —   —    —       —          —\n"
                "Sub/WF               0        —   —    —       —          —\n"
                "-----------------------------------------------------------\n"
                "Total                1        —   —    —       —          —\n"
                "⚠ credits unknown for 1/1 request; 1 incomplete; tokens missing for 1\n"
            ))

    def test_run_without_captures_points_to_the_session_report(self):
        """A call with a foreign process marker leaves the launch empty."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": "b" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_resumed"}}'))
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertEqual(output.getvalue(), "Kiro usage: no calls were captured this run; kiro-usage report --session ID shows a whole session.\n")

    def test_family_without_own_root_reports_why(self):
        """Exit explains missing roots without adding a card, even before the writer adds the index."""
        outer = "a" * 32
        for label, metadata, expected in (
            ("missing identities", {}, "Kiro usage summary unavailable: no captured conversation identity for this invocation.\n"),
            ("external identity", {"kiro:conversation_id": "sess_external"},
             "Kiro usage: no own root session was captured this run; kiro-usage report --session ID shows a whole session.\n"),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                database = root / "usage.sqlite3"
                collector = Collector(database)
                collector.finish(collector.begin({"invocation": outer}, b'{"metadata":{}}'))
                external = {"invocation": "b" * 32, "outermost_invocation": outer}
                collector.finish(collector.begin(external, json.dumps({"metadata": metadata}).encode()))
                collector.close()
                with contextlib.closing(open_database(database)) as db:
                    db.execute("DROP INDEX capture_outermost_invocation")
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.invocation_summary(root, outer, 1 << 30)
                self.assertEqual(output.getvalue(), expected)

    def test_invocation_caveats_print_once_across_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            for session in ("sess_first", "sess_second", None):
                collector.finish(collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": session}}).encode()))
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            text = output.getvalue()
            self.assertEqual((text.count("Kiro usage · sess_first"), text.count("Kiro usage · sess_second")), (1, 1))
            self.assertEqual(text.count("calls with no conversation identity excluded"), 1)
            self.assertLess(text.index("Kiro usage · sess_second"), text.index("calls with no conversation identity excluded"))

    def test_summary_theme_file_styles_the_summary_and_names_a_refused_token(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": "a" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_selected"}}'))
            collector.close()
            for theme, expected in (({"border": "ascii", "color": "always"}, "\n+-"), ({"styles": {"header": "blink"}}, "unavailable: unknown summary style token 'blink'")):
                (root / "theme.json").write_text(json.dumps(theme))
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.invocation_summary(root, "a" * 32, 1 << 30, theme=root / "theme.json")
                self.assertIn(expected, output.getvalue())

    def test_summary_warns_past_the_on_disk_threshold_even_without_captures(self):
        """Hold test-only pages in the WAL to exercise disk growth independent of captured payloads."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "usage.sqlite3"
            Collector(database).close()
            no_calls = "Kiro usage: no calls were captured this run; kiro-usage report --session ID shows a whole session.\n"
            advice = f"stop the kiro-usage service, then archive or delete {database} and its -wal/-shm files to start a new store.\n"
            with self.subTest("database above threshold without a WAL"), contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1024)
                self.assertEqual(output.getvalue(), "Warning: the usage store is 0 MiB on disk, past the 0 MiB warning size; " + advice + no_calls)
            with self.subTest("database below threshold without a WAL"), contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 20)
                self.assertEqual(output.getvalue(), no_calls)
            with contextlib.closing(open_database(database)) as writer:
                writer.execute("PRAGMA wal_autocheckpoint=0")
                writer.execute("CREATE TABLE test_pages (data BLOB)")
                writer.execute("INSERT INTO test_pages VALUES (zeroblob(2097152))")
                writer.commit()
                with self.subTest("WAL pushes the store above threshold"), contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.invocation_summary(root, "a" * 32, 1 << 20)
                    self.assertEqual(output.getvalue(), "Warning: the usage store is 2 MiB on disk, past the 1 MiB warning size; " + advice + no_calls)
                database_bytes = database.stat().st_size
                wal_bytes = database.with_name(f"{database.name}-wal").stat().st_size
                store_bytes = database_bytes + wal_bytes
                with self.subTest("only the combined size exceeds the threshold"), contextlib.redirect_stderr(io.StringIO()) as output:
                    warn_bytes = store_bytes - 1
                    self.assertLess(database_bytes, warn_bytes)
                    self.assertLess(wal_bytes, warn_bytes)
                    runtime.invocation_summary(root, "a" * 32, warn_bytes)
                    self.assertIn("Warning: the usage store is ", output.getvalue())
                with self.subTest("combined size equals the threshold"), contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.invocation_summary(root, "a" * 32, store_bytes)
                    self.assertEqual(output.getvalue(), no_calls)

    def test_summary_runs_without_counting_payload_bytes(self):
        """Refuse a store-wide payload count after collector startup and still render a captured call."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": "a" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_selected"}}'))
            collector.close()
            with patch("store.payload_bytes", side_effect=AssertionError("exit must not count payload bytes")), \
                    contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertIn("Kiro usage · sess_selected · this run · 1 request", output.getvalue())

    def test_service_flag_sets_or_clears_retention_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            for flag, expected in ((["--payload-retention-days", "7"], "7"), ([], None)):
                with self.subTest(expected=expected), patch.dict(os.environ, {"KIRO_USAGE_RETENTION_DAYS": "30"}, clear=True), \
                        patch.object(sys, "argv", ["runtime.py", "service", "--state-dir", str(state), "--port", "19001",
                                                    "--warn-bytes", "1", "--mitmdump", "/mitmdump", "--addon", "/addon", *flag]), \
                        patch.object(runtime.os, "execv") as execute:
                    runtime.main()
                    execute.assert_called_once()
                    self.assertEqual(os.environ.get("KIRO_USAGE_RETENTION_DAYS"), expected)

    def test_root_lineage_is_selected_once_without_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            for invocation, conversation, ancestor in (("a" * 32, "sess_child_one", "root"), ("a" * 32, "sess_child_two", "sess_root"), ("b" * 32, "sess_unrelated", "sess_other")):
                request = {"metadata": {"kiro:conversation_id": conversation, "kiro:root_conversation_id": ancestor}}
                ident = collector.begin({"invocation": invocation}, json.dumps(request).encode())
                collector.finish(ident)
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertEqual(output.getvalue().count("Kiro usage · sess_root · this run · 2 requests"), 1)
            self.assertNotIn("sess_other", output.getvalue())
            self.assertNotIn("Kiro usage · sess_child", output.getvalue())
            self.assertRegex(output.getvalue(), r"Sub/WF\s+2\s")
            self.assertNotIn("Unknown", output.getvalue())

    def test_exec_settles_queued_captures_before_summary(self):
        # Empty store at exit: the first capture commits 150 ms later, while the settle waits.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            self.addCleanup(collector.close)
            def late_capture():
                time.sleep(.15)
                collector.finish(collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_late"}}).encode()))
            def wait(*_):
                worker = threading.Thread(target=late_capture)
                worker.start()
                self.addCleanup(worker.join)
                return 0
            with patch.dict(os.environ, {"HOME": str(root)}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", side_effect=wait), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("Kiro usage · sess_late · this run · 1 request", output.getvalue())
            self.assertNotIn("capture writer still has unfinished calls", output.getvalue())

    def test_settle_requires_quiet_period_before_deadline(self):
        """A finished capture settles only when the quiet poll precedes the deadline."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            invocation = "a" * 32
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": invocation}, b'{"metadata":{"kiro:conversation_id":"sess_root"}}'))
            collector.close()
            for label, quiet_poll, expected in (
                ("after deadline", 2.03125, False),
                ("at deadline", 2.0, False),
                ("before deadline", 1.984375, True),
            ):
                with (self.subTest(label),
                      patch.object(runtime, "SETTLE_TIMEOUT", 2),
                      patch.object(runtime.time, "monotonic", side_effect=(0, 1.875, 1.9375, quiet_poll)),
                      patch.object(runtime.time, "sleep")):
                    self.assertIs(runtime.settle_captures(root, invocation), expected)

    def test_unsettled_wait_flags_unfinished_calls(self):
        """Wait for an identity-less family child and ignore an unrelated recording call."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            outer = "a" * 32
            collector.finish(collector.begin({"invocation": outer}, b'{"metadata":{"kiro:conversation_id":"sess_own"}}'))
            child = collector.begin({"invocation": "b" * 32, "outermost_invocation": outer}, b'{"metadata":{}}')
            collector.begin({"invocation": "c" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_unrelated"}}')
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex=outer)), patch.object(runtime, "SETTLE_TIMEOUT", .3), patch.object(runtime, "invocation_summary", wraps=runtime.invocation_summary) as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertFalse(summary.call_args.kwargs["settled"])
            self.assertIn("capture writer still has unfinished calls; calls with no conversation identity excluded", output.getvalue())
            collector.finish(child)
            self.assertTrue(runtime.settle_captures(root, outer))

    def test_call_finishing_after_wait_timeout_keeps_unfinished_warning(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            ident = collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_late"}}).encode())
            summary = runtime.invocation_summary

            def finish_before_summary(*arguments, **options):
                collector.finish(ident)  # finishes after the wait timed out, before the summary reads
                deadline = time.monotonic() + 5
                with contextlib.closing(sqlite3.connect(root / "usage.sqlite3")) as db:
                    while db.execute("SELECT state FROM captures WHERE id=?", (ident,)).fetchone()[0] == "recording":
                        self.assertLess(time.monotonic(), deadline, "collector did not commit the finished fixture capture")
                        time.sleep(.01)
                summary(*arguments, **options)

            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime, "invocation_summary", side_effect=finish_before_summary), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "SETTLE_TIMEOUT", .2), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("capture writer still has unfinished calls", output.getvalue())

    def test_read_only_missing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertIn("unavailable", output.getvalue())
            self.assertFalse((root / "usage.sqlite3").exists())

    def test_supervised_handoff_preserves_capture_ownership(self):
        """Close a supervised launch after recording a call with the managed child's exported markers."""
        port = 19001
        supervisor = os.getpid()
        card = "Kiro usage · sess_own · this run · 1 request"
        for name, producer_start, receiver_start, process, expected in (
            ("producer lookup fails", None, "100", "a", card),
            ("receiver lookup fails", "100", None, "a", card),
            ("stale handoff", "100", "200", "b", "no own root session was captured this run"),
        ):
            with (
                self.subTest(case=name), tempfile.TemporaryDirectory() as directory,
                patch.dict(os.environ, {}, clear=True),
                patch.object(socket, "create_connection"),
                patch.object(runtime, "process_start_time", side_effect=(producer_start, receiver_start)),
                patch.object(runtime, "uuid") as launch_uuid,
                contextlib.redirect_stderr(io.StringIO()) as output,
            ):
                launch_uuid.uuid4.side_effect = (SimpleNamespace(hex="a" * 32), SimpleNamespace(hex="b" * 32))
                root = Path(directory)
                cert = root / "ca" / "mitmproxy-ca-cert.pem"
                cert.parent.mkdir(mode=0o700)
                cert.write_text("fixture CA")
                captured = {}

                def managed_child(_command, _arguments, values):
                    """Apply the managed wrapper's exports to one fixture capture in place of running Kiro."""
                    with patch.dict(os.environ, values, clear=True), contextlib.redirect_stdout(io.StringIO()) as exports:
                        runtime.environment(root, port, supervisor + 1, supervisor)
                    settings = dict(shlex.split(line)[1].split("=", 1) for line in exports.getvalue().splitlines()
                                    if line.startswith("export "))
                    captured.update(invocation=settings[runtime.INVOCATION],
                                    outermost_invocation=settings[runtime.OUTERMOST_INVOCATION])
                    collector = Collector(root / "usage.sqlite3")
                    try:
                        collector.finish(collector.begin(captured.copy(), b'{"metadata":{"kiro:conversation_id":"sess_own"}}'))
                    finally:
                        collector.close()
                    return 0

                with patch.object(runtime, "wait_command", side_effect=managed_child) as wait:
                    self.assertEqual(runtime.exec_command(root, port, 1 << 30, ["kiro-cli", "chat"]), 0)
                self.assertIn(expected, output.getvalue())
                self.assertEqual(captured, {"invocation": process * 32, "outermost_invocation": "a" * 32})
                self.assertEqual(wait.call_args.args[2][runtime.LAUNCH_HANDOFF],
                                 f"parent:{supervisor}:{producer_start or ''}")

    def test_darwin_start_time_handoff(self):
        """Run the exec and environment handoff with literal Darwin ps output."""
        path = Path("/unused")
        port = 19001
        pid = os.getpid()
        outermost = "a" * 32
        prepared = runtime.InvocationMarkers("b" * 32, outermost)
        timestamp = "Sat Nov  7 12:34:56 2026"
        handoff = f"self:{pid}:Sat Nov  7 12:34:56 2026"
        ps_command = ["/bin/ps", "-o", "lstart=", "-p", str(pid)]
        cases = (
            ("Darwin timestamp is preserved", timestamp + "\n", timestamp + "\n", handoff),
            ("producer lookup fails", "", timestamp + "\n", f"self:{pid}:"),
            ("receiver lookup fails", timestamp + "\n", "", handoff),
        )
        for name, producer_output, receiver_output, expected_handoff in cases:
            with (
                self.subTest(case=name),
                patch.dict(os.environ, {
                    runtime.INVOCATION: "d" * 32,
                    runtime.OUTERMOST_INVOCATION: outermost,
                    runtime.LAUNCH_HANDOFF: f"self:{pid}:stale",
                    "LC_ALL": "POSIX",
                }, clear=True),
                patch.object(sys, "platform", "darwin"),
                patch.object(subprocess, "check_output", return_value=producer_output) as ps,
                patch.object(runtime.uuid, "uuid4", side_effect=(
                    SimpleNamespace(hex="b" * 32), SimpleNamespace(hex="c" * 32),
                )),
                patch.object(runtime, "launch_environment", return_value=dict(os.environ)) as launch,
                patch.object(os, "execvpe") as execute,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                runtime.exec_command(path, port, 1 << 30, ["kiro-cli", "chat"])
                ps.assert_called_once_with(ps_command, env=os.environ | {"LC_ALL": "C"},
                                           stderr=subprocess.DEVNULL, text=True)
                launch.assert_called_once_with(path, port, prepared, refuse_conflicts=False)
                child_environment = execute.call_args.args[2]
                self.assertEqual(child_environment.get(runtime.LAUNCH_HANDOFF), expected_handoff)
                ps.reset_mock()
                ps.return_value = receiver_output
                with patch.dict(os.environ, child_environment | {
                    runtime.INVOCATION: prepared.invocation,
                }, clear=True):
                    runtime.environment(path, port, pid, os.getppid())
                    ps.assert_called_once_with(ps_command, env=os.environ | {"LC_ALL": "C"},
                                               stderr=subprocess.DEVNULL, text=True)
                launch.assert_called_with(path, port, prepared, inherited=prepared)

    def test_darwin_start_time_unavailable(self):
        """Require an unavailable Darwin ps timestamp to return None to launchers."""
        cases = (
            ("empty output", None),
            ("missing executable", FileNotFoundError()),
            ("nonzero exit", subprocess.CalledProcessError(1, "/bin/ps")),
        )
        for name, error in cases:
            with (
                self.subTest(case=name),
                patch.object(sys, "platform", "darwin"),
                patch.object(subprocess, "check_output", return_value="", side_effect=error) as ps,
            ):
                self.assertIsNone(runtime.process_start_time(4321))
                ps.assert_called_once_with(["/bin/ps", "-o", "lstart=", "-p", "4321"],
                                           env=os.environ | {"LC_ALL": "C"}, stderr=subprocess.DEVNULL, text=True)

    def test_linux_start_time_skips_parentheses_in_command(self):
        """Require the Linux stat reader to find field 22 after the full command name."""
        stat_record = (
            b"4321 (kiro) (worker) S 1 4321 4321 0 -1 4194304 123 0 0 0 1 2 0 0 20 0 1 0 "
            b"7654321 123456 42 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 "
            b"0 0 0 0 0 0 0\n"
        )
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(Path, "read_bytes", autospec=True, return_value=stat_record) as read,
        ):
            self.assertEqual(runtime.process_start_time(4321), "7654321")
        read.assert_called_once_with(Path("/proc/4321/stat"))

    def test_launch_marker_lineage(self):
        """Run the environment CLI in a fixture Bash launcher and observe the final executable."""
        root = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="kiro usage 'fixture' ")))
        state_home = root / "state"
        state = state_home / "kiro-cli/usage"
        state.mkdir(mode=0o700, parents=True)
        ca = state / "ca"
        ca.mkdir(mode=0o700)
        cert = ca / "mitmproxy-ca-cert.pem"
        cert.write_text("fixture")
        listener = self.enterContext(socket.socket())
        listener.bind(("127.0.0.1", 0))
        listener.listen(32)
        port = listener.getsockname()[1]
        home = root / "home"
        home.mkdir()
        project = root / "project/kiro-cli"
        managed = root / "managed/kiro-cli"
        for executable in (project, managed):
            executable.parent.mkdir()
            executable.touch(mode=0o700)
        project.write_text(f"""#!{sys.executable}
import json, os, subprocess, sys

keys = ("HTTP_PROXY", "HTTPS_PROXY", "KIRO_USAGE_HANDOFF", "KIRO_USAGE_INVOCATION",
        "KIRO_USAGE_OUTERMOST_INVOCATION", "NODE_EXTRA_CA_CERTS", "http_proxy", "https_proxy")
print(json.dumps({{key: os.environ.get(key) for key in keys}}), flush=True)
for argv, identity in json.loads(sys.argv[-1]):
    subprocess.run(argv, env=os.environ | {{"FIXTURE_ID": identity}}, check=True)
""")
        # Sharing a fixture UUID between entry points would hide a second mint.
        entry = [sys.executable, "-c", """
import os, runtime, sys
from types import SimpleNamespace

runtime.uuid.uuid4 = lambda: SimpleNamespace(hex=os.environ["FIXTURE_ID"] * 31 +
                                            ("a" if sys.argv[1] == "cli" else "b"))
sys.exit(runtime.main())
"""]
        bootstrap = shlex.join([*entry, "environment", "--port", str(port)])
        managed.write_text(f"""#!{shutil.which('bash')}
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nat_usage_environment="$({bootstrap} --launcher-pid "$$" --launcher-parent-pid "$PPID")"
eval "$nat_usage_environment"
unset nat_usage_environment
exec -a "$0" {shlex.quote(str(project))} "$@"
""")
        tool = [*entry, "cli", "--port", str(port), "--warn-bytes", "1073741824",
                "--launch-value-options=" + ",".join(LAUNCH_VALUE_OPTIONS), CHAT_VALUE_OPTIONS_ARG, "--", "exec"]

        def command(executable, *children, explicit=False, quiet=False):
            """Build a fixture launch and the subprocess plan read by fake Kiro."""
            prefix = [*tool, *(["--no-summary"] if not quiet else []), "--"] if explicit else []
            return [*prefix, str(executable), "chat", *(["--no-interactive"] if quiet else []), json.dumps(children)]

        def run(argv, selected=managed, **inherited):
            """Start one scenario with a clean environment and a fixture PATH."""
            return subprocess.run(argv, env={"HOME": str(home), "XDG_STATE_HOME": str(state_home),
                                             "PATH": str(selected.parent), "FIXTURE_ID": "1",
                                             "PYTHONDONTWRITEBYTECODE": "1", **inherited},
                                  cwd=Path(__file__).parent, capture_output=True, text=True, timeout=10)

        def marker(digit, mode):
            """Spell the fixture UUID chosen by each launch mode."""
            return digit * 31 + mode

        def check(result, *identities):
            """Check ordered per-process credentials, shell quoting, and quiet output."""
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(rows), len(identities))
            for row, (process, outer) in zip(rows, identities, strict=True):
                self.assertEqual(row["KIRO_USAGE_INVOCATION"], process)
                self.assertEqual(row["KIRO_USAGE_OUTERMOST_INVOCATION"], outer)
                username = process if process == outer else f"{process}.{outer}"
                for setting in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
                    self.assertEqual(row[setting], f"http://kiro-usage-{username}:@127.0.0.1:{port}", setting)
                self.assertEqual(row["NODE_EXTRA_CA_CERTS"], str(cert))
            return rows

        outer = marker("1", "b")
        child = marker("2", "b")
        grandchild = marker("3", "b")
        sibling = marker("4", "a")
        nested_explicit = command(project, explicit=True)
        nested_managed = command(managed, (command(managed), "3"))
        with self.subTest(launch="nested managed, sibling explicit, grandchild"):
            rows = check(run(command(managed, (nested_managed, "2"), (nested_explicit, "4"))),
                         (outer, outer), (child, outer), (grandchild, outer), (sibling, outer))
            self.assertTrue(all(row["KIRO_USAGE_HANDOFF"] is None for row in rows[:3]))

        explicit = marker("1", "a")
        for quiet in (False, True):
            with self.subTest(launch="explicit PATH to managed", quiet=quiet):
                rows = check(run(command("kiro-cli", (nested_managed, "2"), explicit=True, quiet=quiet)),
                             (explicit, explicit), (child, explicit), (grandchild, explicit))
                self.assertTrue(all(row["KIRO_USAGE_HANDOFF"] is None for row in rows))
            with self.subTest(launch="explicit PATH to project", quiet=quiet):
                replacement = command(managed, explicit=True)
                rows = check(run(command("kiro-cli", (nested_managed, "2"), (replacement, "4"),
                                         explicit=True, quiet=quiet), selected=project),
                             (explicit, explicit), (child, explicit), (grandchild, explicit), (sibling, explicit))
                self.assertTrue(all(row["KIRO_USAGE_HANDOFF"] is None for row in rows[1:]))

        legacy = "f" * 32
        with self.subTest(launch="managed with matching legacy proxy"):
            check(run(command(managed), KIRO_USAGE_INVOCATION=legacy, NODE_EXTRA_CA_CERTS=str(cert),
                      HTTPS_PROXY=f"http://kiro-usage-{legacy}:@127.0.0.1:{port}"), (outer, legacy))
        for setting, value in (("HTTPS_PROXY", "http://invalid.invalid:1"),
                               ("NODE_EXTRA_CA_CERTS", str(root / "unrelated.pem"))):
            with self.subTest(conflict=setting):
                result = run(command(managed), **{setting: value})
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"inherited {setting} conflicts", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_nested_launch_rotates_marker_and_skips_summary(self):
        """Require both nested chat variants to replace the process without waiting or printing."""
        for arguments in (["chat"], ["chat", "--no-interactive"]):
            with (self.subTest(arguments=arguments),
                  patch.dict(os.environ, KIRO_USAGE_INVOCATION="a" * 32, clear=True),
                  patch.object(runtime, "process_start_time", return_value="100"),
                  patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="b" * 32)),
                  patch.object(runtime, "launch_environment", return_value={}) as environment,
                  patch.object(os, "execvpe") as execute,
                  patch.object(runtime, "wait_command") as wait,
                  patch.object(runtime, "settle_captures") as settle,
                  patch.object(runtime, "invocation_summary") as summary):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments])
                environment.assert_called_once_with(Path("/unused"), 19001,
                                                    runtime.InvocationMarkers("b" * 32, "a" * 32), refuse_conflicts=False)
                execute.assert_called_once_with("kiro-cli", ["kiro-cli", "--v3", *arguments],
                                                {"KIRO_USAGE_HANDOFF": f"self:{os.getpid()}:100"})
                wait.assert_not_called()
                settle.assert_not_called()
                summary.assert_not_called()

    def test_only_quiet_launches_exec_with_a_fresh_marker(self):
        cases = (
            ("headless chat", ["kiro-cli", "chat", "--no-interactive"], ["--v3", "chat", "--no-interactive"]),
            ("headless ACP", ["kiro-cli", "acp"], ["--v3", "acp", "--agent-engine=v3"]),
            ("headless ACP with --no-summary", ["--no-summary", "kiro-cli", "acp"],
             ["--v3", "acp", "--agent-engine=v3"]),
            ("stream JSON separate value", ["kiro-cli", "chat", "--output-format", "stream-json"],
             ["--v3", "chat", "--output-format", "stream-json"]),
            ("stream JSON attached value", ["kiro-cli", "chat", "--output-format=stream-json"],
             ["--v3", "chat", "--output-format=stream-json"]),
            ("text output", ["kiro-cli", "chat", "--output-format", "text"], None),
            ("agent value", ["kiro-cli", "chat", "--agent", "--no-interactive"], None),
            ("chat long option value", ["kiro-cli", "chat", "--format", "--no-interactive"], None),
            ("chat short option value", ["kiro-cli", "chat", "-vf", "--no-interactive"], None),
            ("attached short value before flag", ["kiro-cli", "chat", "-vf=json", "--no-interactive"],
             ["--v3", "chat", "-vf=json", "--no-interactive"]),
            ("stream JSON spelling used as another value",
             ["kiro-cli", "chat", "--agent", "--output-format=stream-json"], None),
            ("stream JSON spelling after command separator",
             ["kiro-cli", "chat", "--", "--output-format=stream-json"], None),
            ("after command separator", ["kiro-cli", "chat", "--", "--no-interactive"], None),
            ("exec flag belongs to child", ["kiro-cli", "chat", "--", "--no-summary"], None),
            ("interactive chat", ["kiro-cli", "chat"], None),
        )
        markers = set()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            cert = state / "ca" / "mitmproxy-ca-cert.pem"
            cert.parent.mkdir(mode=0o700)
            cert.write_text("fixture certificate")
            for name, arguments, direct in cases:
                argv = ["runtime.py", "cli", "--state-dir", str(state), "--port", "19001",
                        "--warn-bytes", str(1 << 30), CHAT_VALUE_OPTIONS_ARG,
                        "--launch-value-options=" + ",".join(LAUNCH_VALUE_OPTIONS), "--", "exec", *arguments]
                with (self.subTest(name=name),
                      patch.dict(os.environ, {}, clear=True),
                      patch.object(sys, "argv", argv),
                      patch.object(runtime.socket, "create_connection"),
                      patch.object(os, "execvpe") as execute,
                      patch.object(runtime, "wait_command", return_value=23) as wait,
                      patch.object(runtime, "settle_captures", return_value=True) as settle,
                      patch.object(runtime, "invocation_summary") as summary):
                    result = runtime.main()
                    if direct is None:
                        self.assertEqual(result, 23)
                        execute.assert_not_called()
                        wait.assert_called_once()
                        self.assertEqual(wait.call_args.args[:2], ("kiro-cli", ["--v3", *arguments[1:]]))
                        settle.assert_called_once()
                        summary.assert_called_once()
                    else:
                        execute.assert_called_once()
                        command, argv, environment = execute.call_args.args
                        self.assertEqual((command, argv), ("kiro-cli", ["kiro-cli", *direct]))
                        marker = environment["KIRO_USAGE_INVOCATION"]
                        self.assertRegex(marker, r"^[0-9a-f]{32}$")
                        self.assertNotIn(marker, markers)
                        markers.add(marker)
                        self.assertEqual(environment["HTTPS_PROXY"], f"http://kiro-usage-{marker}:@127.0.0.1:19001")
                        self.assertEqual(environment["NODE_EXTRA_CA_CERTS"], str(cert))
                        wait.assert_not_called()
                        settle.assert_not_called()
                        summary.assert_not_called()

    def test_supervised_child_status_stdout_and_signals(self):
        self._check_supervised_child_status_stdout_and_signals()

    def test_no_summary_supervises_without_settling_or_printing(self):
        self._check_supervised_child_status_stdout_and_signals(no_summary=True)

    def _check_supervised_child_status_stdout_and_signals(self, no_summary=False):
        """Run fixture children to distinguish supervised exits from direct exec."""
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "kiro-cli"
            arguments = ["exec", *(["--no-summary"] if no_summary else []), str(executable), "chat"]
            script = f"""
import runtime
from pathlib import Path

runtime.launch_environment = lambda *args, **kwargs: dict(runtime.os.environ)
runtime.settle_captures = lambda *args: print("settle", file=runtime.sys.stderr)
runtime.invocation_summary = lambda *args, **kwargs: print("summary", file=runtime.sys.stderr)
def unexpected_exec(*args):
    raise AssertionError("expected supervision, got direct exec")

runtime.os.execvpe = unexpected_exec
raise SystemExit(runtime.cli(Path({directory!r}), {arguments!r}, 19001, 1 << 30))
"""
            for body, expected in (("print('machine stdout'); raise SystemExit(23)", 23), ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -signal.SIGTERM), ("import os, signal; os.kill(os.getpid(), signal.SIGKILL)", -signal.SIGKILL)):
                with self.subTest(expected=expected):
                    executable.write_text(f"#!{sys.executable}\n" + body + "\n")
                    executable.chmod(0o700)
                    result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent,
                                            env=supervised_fixture_environment(), capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stderr, "" if no_summary else "settle\nsummary\n")
                    self.assertEqual(result.stdout, "machine stdout\n" if expected == 23 else "")

    def test_terminal_descriptors_and_interrupt(self):
        self._check_terminal(False)

    def test_piped_stdin_terminal_interrupt(self):
        self._check_terminal(True)

    def _check_terminal(self, piped):
        master, slave = pty.openpty()
        script = "import runtime,sys; code=\"import os,signal,time; print('TTY', *(os.isatty(n) for n in (0,1,2)), flush=True); signal.signal(signal.SIGINT, lambda *a: (print('INT',flush=True), time.sleep(.1), sys.exit(0))); time.sleep(20)\"; code='import sys; '+code; result=runtime.wait_command(sys.executable, ['-c',code], dict(runtime.os.environ)); print('EXIT',result,flush=True)"
        process = subprocess.Popen([sys.executable, "-c", script], cwd=Path(__file__).parent,
                                   stdin=subprocess.PIPE if piped else slave, stdout=slave, stderr=slave, start_new_session=True,
                                   preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
        os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 5
            expected = b"TTY False True True" if piped else b"TTY True True True"
            while expected not in output:
                self.assertLess(time.monotonic(), deadline, output)
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 4096)
            # A real foreground terminal delivers one interrupt to both processes.
            time.sleep(.05)
            os.write(master, b"\x03")
            self.assertEqual(process.wait(timeout=5), 0)
            while select.select([master], [], [], .1)[0]:
                try:
                    output += os.read(master, 4096)
                except OSError:
                    break
            self.assertIn(b"EXIT 0", output)
            self.assertEqual(output.count(b"INT\r\n"), 1, output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if process.stdin:
                process.stdin.close()
            os.close(master)

    def test_acp_names_its_engine_before_the_end_of_options_marker(self):
        cases = (
            (["acp"], ["--v3", "acp", "--agent-engine=v3"]),
            (["acp", "--model", "x"], ["--v3", "acp", "--model", "x", "--agent-engine=v3"]),
            (["acp", "--agent-engine=v2"], ["--v3", "acp", "--agent-engine=v2"]),
            (["acp", "--agent-engine", "v3"], ["--v3", "acp", "--agent-engine", "v3"]),
            (["acp", "--"], ["--v3", "acp", "--agent-engine=v3", "--"]),
            (["acp", "--", "--agent-engine=v3"], ["--v3", "acp", "--agent-engine=v3", "--", "--agent-engine=v3"]),
            (["--agent", "acp"], ["--v3", "--agent", "acp"]),
            (["--resume-id", "acp"], ["--v3", "--resume-id", "acp"]),
            (["--model", "acp"], ["--v3", "--model", "acp", "--agent-engine=v3"]),
            (["--agent", "a", "acp"], ["--v3", "--agent", "a", "acp", "--agent-engine=v3"]),
            (["chat"], ["--v3", "chat"]),
            (["chat", "--", "acp"], ["--v3", "chat", "--", "acp"]),
            (["mcp", "list"], ["--v3", "mcp", "list"]),
        )
        for arguments, expected in cases:
            with self.subTest(arguments=arguments), patch.dict(os.environ, {"KIRO_USAGE_INVOCATION": "a" * 32}), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute:
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments], launch_value_options=LAUNCH_VALUE_OPTIONS)
                self.assertEqual(execute.call_args.args[:2], ("kiro-cli", ["kiro-cli", *expected]))
                execute.assert_called_once()

    def test_other_commands_get_no_engine_selector(self):
        with patch.dict(os.environ, {"KIRO_USAGE_INVOCATION": "a" * 32}), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute:
            runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["other-tool", "acp"])
            execute.assert_called_once_with("other-tool", ["other-tool", "acp"], {})

    def test_non_chat_commands_skip_summary(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "invocation_summary") as summary:
            for arguments in (["--version"], ["--help"], ["login"], ["--help-all"], ["chat", "--help"], ["--model", "login"], ["--tui", "login"], ["--agent", "x", "mcp", "list"]):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments], launch_value_options=LAUNCH_VALUE_OPTIONS)
            self.assertEqual(execute.call_count, 8)
            summary.assert_not_called()
            wait.assert_not_called()
            for arguments in (["chat", "please explain login and --version"], ["chat", "--", "--help"], ["--resume-id", "sess_resume"], ["--agent", "doctor"], []):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments], launch_value_options=LAUNCH_VALUE_OPTIONS)
            self.assertEqual(summary.call_count, 5)

    def test_closed_summary_stderr_keeps_child_status(self):
        for status, expected in ((23, 23), (-signal.SIGTERM, -signal.SIGTERM)):
            script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.wait_command=lambda *a: {status}; runtime.invocation_summary=lambda *a, **kw: print('summary',file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, 1 << 30, ['kiro-cli','chat']))"
            reader, writer = os.pipe()
            os.close(reader)
            try:
                result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent,
                                        env=supervised_fixture_environment(), stderr=writer, stdout=subprocess.PIPE)
                self.assertEqual(result.returncode, expected)
                self.assertEqual(result.stdout, b"")
            finally:
                os.close(writer)

    def test_interrupt_during_summary_keeps_child_status(self):
        def interrupt(*arguments, **keywords):
            os.kill(os.getpid(), signal.SIGINT)
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "invocation_summary", side_effect=interrupt):
            self.assertEqual(runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", "chat"]), 23)

    def test_marker_parser_strips_headers_and_cleans_connections(self):
        """Check that CONNECT strips proxy credentials and disconnect drops the stored marker."""
        addon = UsageCapture()
        addon.invocations = {}
        connection = SimpleNamespace(id="local-one")
        def flow(header, client=connection):
            return SimpleNamespace(client_conn=client, request=SimpleNamespace(headers={"proxy-authorization": header}))
        marker = "a" * 32
        credentials = base64.b64encode(f"kiro-usage-{marker}:".encode()).decode()
        request = flow(f"Basic {credentials}")
        addon.http_connect(request)
        self.assertEqual(set(addon.invocations), {"local-one"})
        self.assertNotIn("proxy-authorization", request.request.headers)
        cases = {
            "empty header": "",
            "invalid base64": "Basic !!!",
            "wrong scheme": f"Bearer {credentials}",
        }
        for name, malformed in (
            ("extra dot", f"kiro-usage-{marker}.{'b' * 32}.:"),
            ("nonempty password", f"kiro-usage-{marker}:password"),
            ("short marker", "kiro-usage-bad:"),
            ("uppercase marker", f"kiro-usage-{marker.upper()}:"),
        ):
            cases[name] = "Basic " + base64.b64encode(malformed.encode()).decode()
        for name, header in cases.items():
            with self.subTest(case=name):
                request = flow(header, SimpleNamespace(id="other"))
                addon.http_connect(request)
                self.assertNotIn("other", addon.invocations)
                self.assertNotIn("proxy-authorization", request.request.headers)
        addon.client_disconnected(connection)
        self.assertEqual(addon.invocations, {})

    def test_proxy_credentials_reach_capture_metadata(self):
        """Exercise both proxy hooks and read attribution from finished fixture rows."""
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        database = root / "usage.sqlite3"
        addon = UsageCapture()
        with patch.dict(os.environ, {"KIRO_USAGE_DB": str(database)}, clear=True):
            addon.load(None)

        def flow(name, connection, credentials=None, rpc=False, selected=True):
            headers = {"authorization": "Bearer fixture"}
            if credentials is not None:
                headers["proxy-authorization"] = "Basic " + base64.b64encode(credentials).decode()
            if rpc:
                headers["x-amz-target"] = "KiroRuntimeService.GenerateAssistantResponse"
            body = {"conversationState": {"conversationId": name}} if rpc else {"metadata": {"kiro:conversation_id": name}}
            request = SimpleNamespace(headers=headers, host="fixture.kiro.dev", method="POST",
                                      path="/" if rpc else "/v1/responses" if selected else "/",
                                      get_content=lambda strict: json.dumps(body).encode())
            return SimpleNamespace(id=name, client_conn=SimpleNamespace(id=connection), request=request)

        try:
            tunnel = flow("connect", "tunnel", b"kiro-usage-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:")
            addon.http_connect(tunnel)
            self.assertEqual(tunnel.request.headers, {"authorization": "Bearer fixture"})
            cases = (
                (flow("sess_rest", "tunnel"), ("a" * 32, "b" * 32)),
                (flow("sess_rpc", "direct", b"kiro-usage-cccccccccccccccccccccccccccccccc.dddddddddddddddddddddddddddddddd:", rpc=True), ("c" * 32, "d" * 32)),
                (flow("sess_legacy", "legacy", b"kiro-usage-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:"), ("e" * 32, "e" * 32)),
                (flow("sess_unmarked", "unmarked"), (None, None)),
                (flow("sess_malformed", "malformed", b"kiro-usage-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bad:"), (None, None)),
            )
            skipped = flow("skipped", "skipped", b"kiro-usage-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:", selected=False)
            addon.request(skipped)
            self.assertEqual(skipped.request.headers, {"authorization": "Bearer fixture"})
            for request, _ in cases:
                addon.request(request)
                self.assertNotIn("proxy-authorization", request.request.headers)
                self.assertEqual(request.request.headers["authorization"], "Bearer fixture")
                addon.response(request)
            addon.client_disconnected(tunnel.client_conn)
            reused = flow("sess_reused", "tunnel")
            addon.request(reused)
            addon.response(reused)
        finally:
            addon.done()

        with contextlib.closing(sqlite3.connect(database)) as db:
            metadata = [json.loads(row[0]) for row in db.execute("SELECT metadata_json FROM captures WHERE ended_utc_ns IS NOT NULL")]
        rows = {row["kiro:conversation_id"]: row for row in metadata}
        self.assertEqual(len(metadata), len(cases) + 1)
        for request, expected in (*cases, (reused, (None, None))):
            with self.subTest(request=request.id):
                row = rows[request.id]
                markers = ("invocation", "outermost_invocation")
                self.assertEqual(tuple(row.get(key) for key in markers), expected)
                self.assertEqual(tuple(key in row for key in markers), (expected[0] is not None,) * 2)
                self.assertNotIn("proxy-authorization", json.dumps(row).lower())

    def test_inherited_markers_accept_legacy_and_refuse_invalid_ancestry(self):
        """Check legacy defaults and malformed inherited identities before a launch."""
        process = {"KIRO_USAGE_INVOCATION": "a" * 32}
        outer = {"KIRO_USAGE_OUTERMOST_INVOCATION": "b" * 32}
        for identity, expected in (
            ({**process, **outer}, runtime.InvocationMarkers("a" * 32, "b" * 32)),
            (process, runtime.InvocationMarkers("a" * 32, "a" * 32)),
            ({**process, "KIRO_USAGE_OUTERMOST_INVOCATION": ""}, runtime.InvocationMarkers("a" * 32, "a" * 32)),
            ({}, None),
        ):
            with self.subTest(identity=identity), patch.dict(os.environ, identity, clear=True):
                self.assertEqual(runtime.inherited_markers(), expected)
        for identity in (outer, {"KIRO_USAGE_INVOCATION": "A" * 32}):
            with self.subTest(identity=identity), patch.dict(os.environ, identity, clear=True):
                with self.assertRaises(ValueError):
                    runtime.inherited_markers()

    def test_empty_inherited_markers_allow_launch(self):
        """Treat empty marker variables as absent and supervise a new outer launch."""
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        ca = root / "ca"
        ca.mkdir(mode=0o700)
        (ca / "mitmproxy-ca-cert.pem").write_text("fixture")
        self.enterContext(patch.dict(os.environ, {
            "KIRO_USAGE_INVOCATION": "",
            "KIRO_USAGE_OUTERMOST_INVOCATION": "",
        }, clear=True))
        self.enterContext(patch.object(runtime.socket, "create_connection"))

        with (self.subTest(mode="exec"),
              patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="c" * 32)),
              patch.object(runtime, "wait_command", return_value=23) as wait,
              patch.object(runtime, "settle_captures", return_value=True),
              patch.object(runtime, "invocation_summary") as summary,
              patch.object(os, "execvpe") as execute):
            self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 23)
            execute.assert_not_called()
            wait.assert_called_once()
            values = wait.call_args.args[2]
            self.assertEqual(values["KIRO_USAGE_INVOCATION"], "c" * 32)
            self.assertEqual(values["KIRO_USAGE_OUTERMOST_INVOCATION"], "c" * 32)
            self.assertEqual(values["HTTPS_PROXY"], "http://kiro-usage-cccccccccccccccccccccccccccccccc:@127.0.0.1:19001")
            summary.assert_called_once_with(root, "c" * 32, 1 << 30, settled=True, theme=None)

    def test_report_alone_receives_the_summary_theme(self):
        script = Path(runtime.__file__).parent
        db = ["--db", "/state/usage.sqlite3"]
        for arguments, invocation in ((["report", "--session", "sess_root"], ["report.py", *db, "--refresh-history", "--session", "sess_root", "--summary-theme", "/theme.json"]),
                                      (["session", "sess_root", "--json"], ["query.py", *db, "--refresh-history", "--session", "sess_root", "--json"])):
            with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
                runtime.cli(Path("/state"), arguments, 19001, 1 << 30, "/theme.json")
            execute.assert_called_once_with(sys.executable, [sys.executable, str(script / invocation[0]), *invocation[1:]])
        with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
            runtime.cli(Path("/state"), ["report"], 19001, 1 << 30)
        execute.assert_called_once_with(sys.executable, [sys.executable, str(script / "report.py"), *db, "--refresh-history"])
        with self.assertRaisesRegex(ValueError, r"\|report \[--since YYYY-MM-DD\]"):
            runtime.cli(Path("/state"), ["summary"], 19001, 1 << 30)

    def test_list_and_unpack_route_to_the_capture_cli(self):
        script = Path(runtime.__file__).parent
        for arguments in (["list"], ["unpack", "ID", "events"]):
            with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
                runtime.cli(Path("/state"), arguments, 19001, 1 << 30)
            execute.assert_called_once_with(sys.executable, [sys.executable, str(script / "capture.py"), "--db", "/state/usage.sqlite3", *arguments])

    def test_main_returns_child_status(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--warn-bytes", "1",
                                       "--chat-value-options=--format,-f", "--launch-value-options=--agent,--repo",
                                       "--", "exec", "--no-summary", "kiro-cli"]), patch.object(runtime, "cli", return_value=23) as cli:
            self.assertEqual(runtime.main(), 23)
        self.assertEqual(cli.call_args.args[1], ["--", "exec", "--no-summary", "kiro-cli"])
        self.assertEqual(cli.call_args.args[-2:], (["--agent", "--repo"], ["--format", "-f"]))

    def test_cli_refuses_to_start_without_the_launch_value_options(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--warn-bytes", "1", "--", "exec", "kiro-cli"]), \
                patch.object(runtime, "cli") as cli, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            runtime.main()
        cli.assert_not_called()


if __name__ == "__main__":
    unittest.main()

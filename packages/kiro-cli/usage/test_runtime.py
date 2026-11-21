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
import signal
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

    def test_run_counts_only_its_own_captures_per_root(self):
        # One run that switched or forked: two roots, each also captured by an earlier run that must stay out.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            for invocation, conversation, ancestor in (("a" * 32, "sess_first", None), ("a" * 32, "sess_helper", "first"),
                                                       ("a" * 32, "sess_fork", None), ("b" * 32, "sess_first", None),
                                                       ("b" * 32, "sess_first", None), ("b" * 32, "sess_fork", None)):
                request = {"metadata": {"kiro:conversation_id": conversation, "kiro:root_conversation_id": ancestor}}
                collector.finish(collector.begin({"invocation": invocation}, json.dumps(request).encode()))
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            text = output.getvalue()
            self.assertEqual((text.count("Kiro usage · sess_first · this run · 2 requests"), text.count("Kiro usage · sess_fork · this run · 1 request ")), (1, 1))
            self.assertEqual(text.count("Kiro usage ·"), 2)
            self.assertRegex(text, r"Main\s+1\s.*\n.*Sub/WF\s+1\s")

    def test_run_without_captures_points_to_the_session_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": "b" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_resumed"}}'))
            collector.close()
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertEqual(output.getvalue(), "Kiro usage: no calls were captured this run; kiro-usage report --session ID shows a whole session.\n")

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

    def test_unsettled_wait_flags_unfinished_calls(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_open"}}).encode())
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "SETTLE_TIMEOUT", .3), patch.object(runtime, "invocation_summary", wraps=runtime.invocation_summary) as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("capture writer still has unfinished calls", output.getvalue())
            self.assertFalse(summary.call_args.kwargs["settled"])

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

    def test_nested_launch_reuses_marker_and_skips_summary(self):
        for arguments in (["chat"], ["chat", "--no-interactive"]):
            with (self.subTest(arguments=arguments),
                  patch.dict(os.environ, KIRO_USAGE_INVOCATION="a" * 32, clear=True),
                  patch.object(runtime, "launch_environment", return_value={}) as environment,
                  patch.object(os, "execvpe") as execute,
                  patch.object(runtime, "wait_command") as wait,
                  patch.object(runtime, "settle_captures") as settle,
                  patch.object(runtime, "invocation_summary") as summary):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments])
                environment.assert_called_once_with(Path("/unused"), 19001, refuse_conflicts=False, invocation="a" * 32)
                execute.assert_called_once_with("kiro-cli", ["kiro-cli", "--v3", *arguments], {})
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
                    env = dict(os.environ)
                    env.pop("KIRO_USAGE_INVOCATION", None)
                    result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent, env=env, capture_output=True, text=True)
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
                execute.assert_called_once_with("kiro-cli", ["kiro-cli", *expected], {})

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
            environment = dict(os.environ)
            environment.pop("KIRO_USAGE_INVOCATION", None)
            try:
                result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent, env=environment, stderr=writer, stdout=subprocess.PIPE)
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
        addon = UsageCapture()
        addon.invocations = {}
        connection = SimpleNamespace(id="local-one")
        def flow(header, client=connection):
            return SimpleNamespace(client_conn=client, request=SimpleNamespace(headers={"proxy-authorization": header}))
        marker = "a" * 32
        valid = "Basic " + base64.b64encode(f"kiro-usage-{marker}:".encode()).decode()
        request = flow(valid)
        addon.http_connect(request)
        self.assertEqual(addon.invocations, {"local-one": marker})
        self.assertNotIn("proxy-authorization", request.request.headers)
        for header in ("", "Basic !!!", "Bearer ignored", "Basic " + base64.b64encode(b"kiro-usage-bad:").decode(), "Basic " + base64.b64encode(f"kiro-usage-{marker}:password".encode()).decode()):
            request = flow(header, SimpleNamespace(id="other"))
            addon.http_connect(request)
            self.assertNotIn("other", addon.invocations)
            self.assertNotIn("proxy-authorization", request.request.headers)
        addon.client_disconnected(connection)
        self.assertEqual(addon.invocations, {})

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

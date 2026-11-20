"""Offline launch summaries use exact identity and preserve command behavior."""
# cspell:words preexec TIOCSCTTY
import base64
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import contextlib
import fcntl
from functools import partial
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

from capture import Collector, lock_beside, open_database
import disk_index
from mitm_addon import UsageCapture
import runtime

# The top-level options that take a value, as the packaged tool is handed them: the check exports the list measured from the binary's help.
def _launch_value_options():
    measured = os.environ.get("KIRO_LAUNCH_VALUE_OPTIONS")
    if not measured:
        raise RuntimeError(
            "KIRO_LAUNCH_VALUE_OPTIONS is unset. Export the measured list, comma separated, e.g. "
            "KIRO_LAUNCH_VALUE_OPTIONS=\"$(nix eval --impure --raw --expr 'let lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib; "
            "in lib.concatStringsSep \",\" (import ./packages/kiro-cli/lib/launchValueOptions.nix {inherit lib;}).measured')\" "
            "(see packages/kiro-cli/usage/README.md)"
        )
    return tuple(measured.split(","))


LAUNCH_VALUE_OPTIONS = _launch_value_options()


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

    @staticmethod
    def writing_child(status, write):
        """A fake Kiro that writes its session files after the launch timestamp, as the real one does."""
        def run(*arguments):
            time.sleep(.05)  # Past one coarse kernel clock tick, so mtimes cannot trail the launch reading.
            write()
            return status
        return run

    def test_exec_refreshes_incremental_disk_before_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            ident = collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_auto"}}).encode())
            collector.finish(ident)
            collector.close()
            session = root / ".kiro/sessions/workspace/sess_auto"
            messages = session / "messages.jsonl"
            record = json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": [{"usage": 1.5, "unit": "credit"}]}}) + "\n"
            def first_turn():
                session.mkdir(parents=True)
                (session / "session.json").write_text(json.dumps({"modelId": "local-model", "parentSessionId": "sess_parent"}))
                messages.write_text(record)
            def resumed_turn():
                with messages.open("a") as stream:
                    stream.write(record)
            with patch.dict(os.environ, {"HOME": str(root)}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(disk_index, "MTIME_SLACK_NS", 0), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)):
                for turns, write in ((1, first_turn), (2, resumed_turn)):
                    with patch.object(runtime, "wait_command", side_effect=self.writing_child(23, write)), contextlib.redirect_stderr(io.StringIO()) as output:
                        self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 23)
                    with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                        self.assertEqual(db.execute("SELECT count(*) FROM disk_records WHERE kind='usage_summary'").fetchone()[0], turns)
                        self.assertEqual(db.execute("SELECT json_extract(identifiers_json,'$.parentSessionId') FROM disk_sessions").fetchone()[0], "sess_parent")
                    self.assertIn("Kiro usage · sess_auto · this run · 1 request · — credits", output.getvalue())  # disk credits stay out

    def test_exec_settles_queued_captures_before_refresh(self):
        # Empty store at exit: the first capture commits 150 ms later, while the settle waits.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            self.addCleanup(collector.close)
            def late_capture():
                time.sleep(.15)
                collector.finish(collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_late"}}).encode()))
            def write():
                session = root / ".kiro/sessions/workspace/sess_late"
                session.mkdir(parents=True)
                (session / "session.json").write_text("{}")
                (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary"}}) + "\n")
                threading.Thread(target=late_capture).start()
            with patch.dict(os.environ, {"HOME": str(root)}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(disk_index, "MTIME_SLACK_NS", 0), patch.object(runtime, "wait_command", side_effect=self.writing_child(0, write)), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 1)

    def test_unsettled_wait_flags_unfinished_calls(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_open"}}).encode())
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime, "refresh_disk_index"), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "SETTLE_TIMEOUT", .3), patch.object(runtime, "invocation_summary", wraps=runtime.invocation_summary) as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("capture writer still has unfinished calls", output.getvalue())
            self.assertFalse(summary.call_args.kwargs["settled"])

    def test_call_finishing_after_wait_timeout_keeps_unfinished_warning(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            ident = collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_late"}}).encode())
            def refresh(*_, **_options):
                collector.finish(ident)  # finishes after the wait timed out, before the summary reads
                with sqlite3.connect(root / "usage.sqlite3") as db:
                    while db.execute("SELECT state FROM captures WHERE id=?", (ident,)).fetchone()[0] == "recording":
                        time.sleep(.01)
                db.close()
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime, "refresh_disk_index", side_effect=refresh), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "SETTLE_TIMEOUT", .2), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("capture writer still has unfinished calls", output.getvalue())

    def test_exec_refresh_reads_only_sessions_modified_during_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            for invocation, conversation in (("a" * 32, "sess_new"), ("b" * 32, "sess_old")):
                ident = collector.begin({"invocation": invocation}, json.dumps({"metadata": {"kiro:conversation_id": conversation}}).encode())
                collector.finish(ident)
            collector.close()
            def write(name):
                session = root / ".kiro/sessions/workspace" / name
                session.mkdir(parents=True)
                (session / "session.json").write_text("{}")
                (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary"}}) + "\n")
                return session
            old = write("sess_old")
            for path in (old / "session.json", old / "messages.jsonl"):
                os.utime(path, ns=(1, 1))
            with patch.dict(os.environ, {"HOME": str(root)}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(disk_index, "MTIME_SLACK_NS", 0), patch.object(runtime, "wait_command", side_effect=self.writing_child(0, lambda: write("sess_new"))), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertEqual([Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions")], ["sess_new"])

    def test_exit_refresh_work_with_indexed_history(self):
        """Count capture scope reads and filesystem probes while an exit indexes new lineage."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            sessions = root / ".kiro/sessions"
            current = "a" * 32

            def write_session(workspace, name, parent=None, old=False):
                path = sessions / workspace / name
                path.mkdir(parents=True, exist_ok=True)
                metadata, messages = path / "session.json", path / "messages.jsonl"
                metadata.write_text(json.dumps({"parentSessionId": parent} if parent else {}))
                messages.write_text(json.dumps({"payload": {"type": "usage_summary"}}) + "\n")
                if old:
                    for file in (metadata, messages):
                        os.utime(file, ns=(1, 1))

            collector = Collector(database)
            try:
                for index in range(64):
                    name = f"sess_history_{index:02}"
                    workspace = "main" if index < 32 else "archive"
                    collector.finish(collector.begin({"invocation": "b" * 32},
                        json.dumps({"metadata": {"kiro:conversation_id": name}}).encode()))
                    write_session(workspace, name, old=True)
                collector.finish(collector.begin({"invocation": current},
                    json.dumps({"metadata": {"kiro:conversation_id": "sess_launch"}}).encode()))
            finally:
                collector.close()
            with contextlib.closing(open_database(database)) as db:
                disk_index.index_tree(db, sessions)
                self.assertEqual(db.execute("SELECT count(*) FROM disk_sessions").fetchone()[0], 64)
                db.execute("DROP INDEX IF EXISTS capture_invocation")
            Collector(database).close()

            def write_launch():
                write_session("main", "sess_launch")
                write_session("main", "sess_helper", "sess_launch")
                history = sessions / "archive/sess_history_63/messages.jsonl"
                with history.open("a") as stream:
                    stream.write('{"payload":{"type":"usage_summary"}}\n')

            historical_reads, statements = [], []
            directory_probes, file_probes = 0, 0

            def stat_path(probe, path, *args, **kwargs):
                nonlocal directory_probes, file_probes
                if isinstance(path, (Path, str)):
                    path = Path(path)
                    if path.parent.parent == sessions and path.name.startswith("sess_"):
                        directory_probes += 1
                    if path.parent.parent.parent == sessions and path.parent.name.startswith("sess_"):
                        file_probes += 1
                return probe(path, *args, **kwargs)

            def json_extract(data, path):
                value = json.loads(data) if data else {}
                key = path[2:].strip('"')
                if value.get("invocation") == "b" * 32:
                    historical_reads.append(path)
                return value.get(key)

            connect = sqlite3.connect

            def traced_connect(*args, **kwargs):
                db = connect(*args, **kwargs)
                db.create_function("json_extract", 2, json_extract, deterministic=True)
                db.set_trace_callback(statements.append)
                return db

            with (
                patch.dict(os.environ, {"HOME": directory}, clear=True),
                patch.object(runtime, "launch_environment", return_value={}),
                patch.object(runtime, "wait_command", side_effect=self.writing_child(0, write_launch)),
                patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex=current)),
                patch.object(sqlite3, "connect", side_effect=traced_connect),
                patch.object(os, "lstat", side_effect=partial(stat_path, os.lstat)),
                patch.object(os, "stat", side_effect=partial(stat_path, os.stat)),
                contextlib.redirect_stderr(io.StringIO()) as output,
            ):
                self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertNotIn("automatic Kiro session indexing failed", output.getvalue())
            self.assertEqual(len(historical_reads), 0, f"Historical JSON evaluations by path: {dict(Counter(historical_reads))}")
            self.assertEqual(file_probes, 4)  # Two files each for the launch and its new helper.
            self.assertEqual(directory_probes, 2)  # Direct lookup in each workspace.
            with contextlib.closing(open_database(database)) as db:
                names = {Path(row[0]).name for row in db.execute("SELECT session_path FROM disk_sources")}
                self.assertTrue({"sess_launch", "sess_helper"} <= names)
                self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 66)
                reads = [sql for sql in statements if sql.startswith("SELECT json_extract") and "FROM captures" in sql]
                self.assertEqual(len(reads), 1)
                plan = db.execute("EXPLAIN QUERY PLAN " + reads[0]).fetchone()[3]
                self.assertIn("SEARCH captures USING INDEX capture_invocation", plan)
                lineage_plans = {db.execute("EXPLAIN QUERY PLAN " + sql).fetchone()[3]
                                 for sql in statements if sql.startswith("SELECT path FROM disk_sessions WHERE json_extract")}
                self.assertEqual(lineage_plans, {
                    "SEARCH disk_sessions USING INDEX disk_sessions_ownerSessionId (<expr>=?)",
                    "SEARCH disk_sessions USING INDEX disk_sessions_parentSessionId (<expr>=?)",
                    "SEARCH disk_sessions USING INDEX disk_sessions_rootConversationId (<expr>=?)",
                    "SEARCH disk_sessions USING INDEX disk_sessions_rootSessionId (<expr>=?)",
                })

    def test_refresh_skips_while_full_index_holds_lock(self):
        """Queue exits under contention and after a failed pass, then index them on retry."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            invocation = "a" * 32
            collector = Collector(state / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": invocation}, json.dumps({"metadata": {"kiro:conversation_id": "sess_auto"}}).encode()))
            collector.close()
            session = root / ".kiro/sessions/workspace/sess_auto"
            session.mkdir(parents=True)
            (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": []}}) + "\n")
            held = lock_beside(state / "usage.sqlite3", disk_index.INDEX_LOCK, blocking=True)
            try:
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.refresh_disk_index(state, 0, invocation)
            finally:
                os.close(held)
            self.assertEqual(output.getvalue().count("\n"), 1)
            self.assertIn("full Kiro session index is running", output.getvalue())
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='disk_records'").fetchone())
            with patch.object(disk_index, "index_tree", side_effect=sqlite3.OperationalError("fixture failure")), contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.refresh_disk_index(state, 0, "b" * 32)
            self.assertIn("automatic Kiro session indexing failed", output.getvalue())
            runtime.refresh_disk_index(state, 0, "c" * 32)
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 1)
                self.assertEqual(db.execute("SELECT count(*) FROM disk_refresh_pending").fetchone()[0], 0)
            held = lock_beside(state / "usage.sqlite3", disk_index.INDEX_LOCK, shared=True)  # a concurrent launch's exit refresh
            try:
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.refresh_disk_index(state, 0, invocation)
            finally:
                os.close(held)
            self.assertEqual(output.getvalue(), "")

    def test_queued_exits_share_one_refresh(self):
        """Enqueue three exits before the snapshot and refresh all three together."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            sessions = root / ".kiro/sessions"
            launches = (("a" * 32, 1), ("b" * 32, 3_000_000_000), ("c" * 32, 3_000_000_000))
            collector = Collector(database)
            try:
                for (invocation, since), name in zip(launches, ("sess_alpha", "sess_beta", "sess_gamma"), strict=True):
                    collector.finish(collector.begin({"invocation": invocation},
                        json.dumps({"metadata": {"kiro:conversation_id": name}}).encode()))
                    session = sessions / "workspace" / name
                    session.mkdir(parents=True)
                    metadata = session / "session.json"
                    metadata.write_text("{}")
                    os.utime(metadata, ns=(since, since))
            finally:
                collector.close()

            queued = threading.Barrier(3, timeout=10)
            refreshed = threading.Event()
            caller = threading.local()

            def wait_for_exits(path, suffix, **kwargs):
                if suffix == disk_index.REFRESH_LOCK:
                    queued.wait()
                    if caller.invocation != "b" * 32:
                        self.assertTrue(refreshed.wait(10))
                return lock_beside(path, suffix, **kwargs)

            def refresh(invocation, since):
                caller.invocation = invocation
                try:
                    runtime.refresh_disk_index(state, since, invocation)
                finally:
                    if invocation == "b" * 32:
                        refreshed.set()

            with (
                patch("capture.lock_beside", side_effect=wait_for_exits),
                patch.object(os, "scandir", wraps=os.scandir) as scandir,
                contextlib.redirect_stderr(io.StringIO()) as output,
                ThreadPoolExecutor(max_workers=3) as workers,
            ):
                exits = [workers.submit(refresh, invocation, since) for invocation, since in launches]
                for finished in exits:
                    finished.result()
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(sum(call.args == (sessions,) for call in scandir.call_args_list), 1)
            with contextlib.closing(sqlite3.connect(database)) as db:
                self.assertEqual(
                    sorted(Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions")),
                    ["sess_alpha", "sess_beta", "sess_gamma"],
                )
                self.assertEqual(db.execute("SELECT count(*) FROM disk_refresh_pending").fetchone()[0], 0)
            self.assertEqual(os.stat(str(database) + disk_index.REFRESH_LOCK).st_mode & 0o777, 0o600)

    def test_enqueue_after_refresh_snapshot_survives_acknowledgement(self):
        """Commit B while A owns its snapshot, then refresh B on the next pass."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            sessions = root / ".kiro/sessions/workspace"
            first, second = "a" * 32, "b" * 32
            collector = Collector(database)
            for invocation, name in ((first, "sess_alpha"), (second, "sess_beta")):
                collector.finish(collector.begin({"invocation": invocation},
                    json.dumps({"metadata": {"kiro:conversation_id": name}}).encode()))
                session = sessions / name
                session.mkdir(parents=True)
                (session / "session.json").write_text("{}")
            collector.close()
            index_tree = disk_index.index_tree

            def enqueue_second(db, root, **options):
                with contextlib.closing(open_database(database)) as other, other:
                    other.execute("INSERT INTO disk_refresh_pending(invocation,since_ns) VALUES (?,0)", (second,))
                return index_tree(db, root, **options)

            with patch.object(disk_index, "index_tree", side_effect=enqueue_second):
                runtime.refresh_disk_index(state, 0, first)
            with contextlib.closing(sqlite3.connect(database)) as db:
                self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [(second,)])
                self.assertEqual([Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions")],
                                 ["sess_alpha"])
                runtime.refresh_disk_index(state, 0, second)
                self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [])
                self.assertEqual([Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions ORDER BY path")],
                                 ["sess_alpha", "sess_beta"])

    def test_unreadable_transcript_does_not_block_other_queued_exits(self):
        """Keep committed metadata and transcript facts when one of two transcript opens fails."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            sessions = root / ".kiro/sessions/workspace"
            bad, good = sessions / "sess_alpha", sessions / "sess_beta"
            record = b'{"payload":{"type":"usage_summary"}}\n'
            first, second = "a" * 32, "b" * 32
            collector = Collector(database)
            for invocation, session in ((first, bad), (second, good)):
                collector.finish(collector.begin({"invocation": invocation},
                    json.dumps({"metadata": {"kiro:conversation_id": session.name}}).encode()))
            collector.close()
            bad.mkdir(parents=True)
            (bad / "session.json").write_text('{"modelId":"prior"}')
            (bad / "messages.jsonl").write_bytes(record)
            runtime.refresh_disk_index(state, 0, first)
            (bad / "session.json").write_text('{"modelId":"new"}')
            good.mkdir()
            (good / "session.json").write_text('{"modelId":"healthy"}')
            (good / "messages.jsonl").write_bytes(record)
            with contextlib.closing(open_database(database)) as db, db:
                db.execute("INSERT INTO disk_refresh_pending(invocation,since_ns) VALUES (?,0)", (first,))

            open_path = Path.open

            def deny_messages(path, *args, **kwargs):
                if path == bad / "messages.jsonl":
                    raise PermissionError("fixture content that must not appear in a warning")
                return open_path(path, *args, **kwargs)

            with patch.object(Path, "open", deny_messages), contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.refresh_disk_index(state, 0, second)
            with contextlib.closing(sqlite3.connect(database)) as db:
                self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [])
                self.assertEqual(db.execute("SELECT model_id FROM disk_sessions ORDER BY path").fetchall(),
                                 [("new",), ("healthy",)])
                self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 2)
            self.assertEqual(output.getvalue(),
                             f"Warning: could not read Kiro session {bad}; disk observations may be stale.\n")

    def test_exit_skips_a_directory_entry_that_cannot_be_classified(self):
        """Keep indexing the healthy sibling and acknowledge the launch after a failed is_dir."""
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            database = state / "usage.sqlite3"
            workspace = root / ".kiro/sessions/workspace"
            bad, good = workspace / "sess_alpha", workspace / "sess_beta"
            invocation = "a" * 32
            Collector(database).close()
            for session in (bad, good):
                session.mkdir(parents=True)
                (session / "session.json").write_text('{"parentSessionId":"sess_root"}')
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

            with patch.object(os, "scandir", scan_entries), contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.refresh_disk_index(state, 0, invocation, resume_id="sess_root")
            with contextlib.closing(sqlite3.connect(database)) as db:
                self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [])
                self.assertEqual(db.execute("SELECT path FROM disk_sessions").fetchall(), [(str(good),)])
            self.assertEqual(output.getvalue(),
                             f"Warning: could not read Kiro session {bad}; disk observations may be stale.\n")

    def test_exit_skips_a_workspace_that_cannot_be_listed(self):
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
                invocation = "a" * 32
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
                    runtime.refresh_disk_index(state, 0, invocation, resume_id="sess_root")
                with contextlib.closing(sqlite3.connect(database)) as db:
                    self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [])
                    self.assertEqual(sorted(row[0] for row in db.execute("SELECT path FROM disk_sessions")),
                                     [str(sessions / name) for name in expected])
                self.assertEqual(output.getvalue(),
                                 f"Warning: could not read Kiro workspace {broken}; disk observations may be stale.\n")

    def test_resume_without_captures_refreshes_an_indexed_session(self):
        """Append inside an indexed session during a no-call resume and count the new record."""
        cases = (
            ("bare launch", ["--resume-id", "resume"]),
            ("chat", ["chat", "--resume-id=sess_resume", "--", "--resume-id=ignored"]),
            ("chat following another option value", ["--agent", "agent-name", "chat", "--resume-id", "sess_resume"]),
        )
        for label, args in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
                root = Path(directory)
                state = root / "state"
                database = state / "usage.sqlite3"
                session = root / ".kiro/sessions/workspace/sess_resume"
                session.mkdir(parents=True)
                messages = session / "messages.jsonl"
                record = '{"payload":{"type":"usage_summary"}}\n'
                messages.write_text(record)
                collector = Collector(database)
                prior = "b" * 32
                collector.finish(collector.begin({"invocation": prior},
                    b'{"metadata":{"kiro:conversation_id":"sess_resume"}}'))
                collector.close()
                runtime.refresh_disk_index(state, 0, prior)
                os.utime(session.parent, ns=(1, 1))

                def append():
                    with messages.open("a") as stream:
                        stream.write(record)

                with (
                    patch.object(runtime, "launch_environment", return_value={}),
                    patch.object(runtime, "wait_command", side_effect=self.writing_child(0, append)),
                    patch.object(runtime, "SETTLE_TIMEOUT", 0),
                    contextlib.redirect_stderr(io.StringIO()) as output,
                ):
                    self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", *args],
                                                         launch_value_options=LAUNCH_VALUE_OPTIONS), 0)
                self.assertIn("no calls were captured this run", output.getvalue())
                with contextlib.closing(sqlite3.connect(database)) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 2)

    def test_settle_timeout_keeps_launch_for_one_later_refresh(self):
        """On a timed-out exit, pick up a late capture on retry or clear the empty launch."""
        for label, late_capture, expected in (("late capture", True, ["sess_late"]), ("no capture", False, [])):
            with self.subTest(label), tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
                root = Path(directory)
                state = root / "state"
                database = state / "usage.sqlite3"
                first = "a" * 32
                Collector(database).close()
                session = root / ".kiro/sessions/workspace/sess_late"
                session.mkdir(parents=True)
                (session / "session.json").write_text("{}")
                with (
                    patch.object(runtime, "launch_environment", return_value={}),
                    patch.object(runtime, "wait_command", return_value=0),
                    patch.object(runtime, "SETTLE_TIMEOUT", 0),
                    patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex=first)),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
                with contextlib.closing(sqlite3.connect(database)) as db:
                    self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [(first,)])
                    self.assertEqual(db.execute("SELECT path FROM disk_sessions").fetchall(), [])
                    if late_capture:
                        collector = Collector(database)
                        collector.finish(collector.begin({"invocation": first},
                            b'{"metadata":{"kiro:conversation_id":"sess_late"}}'))
                        collector.close()
                    runtime.refresh_disk_index(state, time.time_ns(), "b" * 32)
                    self.assertEqual(db.execute("SELECT invocation FROM disk_refresh_pending").fetchall(), [])
                    self.assertEqual([Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions")], expected)

    def test_index_missing_tree_and_failure_are_nonfatal(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            runtime.refresh_disk_index(root / "missing", 0, "a" * 32)
            self.assertFalse((root / "missing").exists())
            sessions = root / ".kiro/sessions"
            sessions.parent.mkdir()
            sessions.write_text("not a directory")
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "invocation_summary") as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root / "state", 19001, 1 << 30, ["kiro-cli", "chat"]), 23)
            self.assertIn("automatic Kiro session indexing failed", output.getvalue())
            summary.assert_called_once()

    def test_failed_index_preserves_child_signal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".kiro").mkdir()
            (root / ".kiro/sessions").write_text("not a directory")
            script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.wait_command=lambda *a: -15; runtime.invocation_summary=lambda *a, **kw: None; raise SystemExit(runtime.exec_command(Path({str(root / 'state')!r}), 19001, 1 << 30, ['kiro-cli','chat']))"
            environment = dict(os.environ, HOME=str(root))
            environment.pop("KIRO_USAGE_INVOCATION", None)
            result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, -signal.SIGTERM)
            self.assertEqual(result.stdout, "")
            self.assertIn("automatic Kiro session indexing failed", result.stderr)

    def test_read_only_missing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, 1 << 30)
            self.assertIn("unavailable", output.getvalue())
            self.assertFalse((root / "usage.sqlite3").exists())

    def test_nested_launch_reuses_marker_and_skips_summary(self):
        with patch.dict(os.environ, {"KIRO_USAGE_INVOCATION": "a" * 32}), patch.object(runtime, "launch_environment", return_value={}) as environment, patch.object(os, "execvpe") as execute, patch.object(runtime, "refresh_disk_index") as refresh, patch.object(runtime, "invocation_summary") as summary:
            runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", "chat"])
            environment.assert_called_once_with(Path("/unused"), 19001, refuse_conflicts=False, invocation="a" * 32)
            execute.assert_called_once_with("kiro-cli", ["kiro-cli", "--v3", "chat"], {})
            summary.assert_not_called()
            refresh.assert_not_called()

    def test_supervised_child_status_stdout_and_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "kiro-cli"
            for body, expected in (("print('machine stdout'); raise SystemExit(23)", 23), ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -signal.SIGTERM), ("import os, signal; os.kill(os.getpid(), signal.SIGKILL)", -signal.SIGKILL)):
                executable.write_text(f"#!{sys.executable}\n" + body + "\n")
                executable.chmod(0o700)
                script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.refresh_disk_index=lambda *a, **kw: None; runtime.invocation_summary=lambda *a, **kw: print('summary', file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, 1 << 30, [{str(executable)!r}]))"
                env = dict(os.environ)
                env.pop("KIRO_USAGE_INVOCATION", None)
                result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stderr, "summary\n")
                if expected == 23:
                    self.assertEqual(result.stdout, "machine stdout\n")

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
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "refresh_disk_index"), patch.object(runtime, "invocation_summary") as summary:
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
            script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.wait_command=lambda *a: {status}; runtime.refresh_disk_index=lambda *a, **kw: None; runtime.invocation_summary=lambda *a, **kw: print('summary',file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, 1 << 30, ['kiro-cli','chat']))"
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
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "refresh_disk_index"), patch.object(runtime, "invocation_summary", side_effect=interrupt):
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
        for arguments, invocation in ((["report", "--session", "sess_root"], ["report.py", *db, "--session", "sess_root", "--summary-theme", "/theme.json"]),
                                      (["session", "sess_root", "--json"], ["query.py", *db, "--session", "sess_root", "--json"])):
            with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
                runtime.cli(Path("/state"), arguments, 19001, 1 << 30, "/theme.json")
            execute.assert_called_once_with(sys.executable, [sys.executable, str(script / invocation[0]), *invocation[1:]])
        with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
            runtime.cli(Path("/state"), ["report"], 19001, 1 << 30)
        execute.assert_called_once_with(sys.executable, [sys.executable, str(script / "report.py"), *db])
        with self.assertRaisesRegex(ValueError, r"\|report \[--since YYYY-MM-DD\]"):
            runtime.cli(Path("/state"), ["summary"], 19001, 1 << 30)

    def test_list_and_unpack_route_to_the_capture_cli(self):
        script = Path(runtime.__file__).parent
        for arguments in (["list"], ["unpack", "ID", "events"]):
            with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
                runtime.cli(Path("/state"), arguments, 19001, 1 << 30)
            execute.assert_called_once_with(sys.executable, [sys.executable, str(script / "capture.py"), "--db", "/state/usage.sqlite3", *arguments])

    def test_main_returns_child_status(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--warn-bytes", "1", "--launch-value-options=--agent,--repo", "--", "exec", "kiro-cli"]), patch.object(runtime, "cli", return_value=23) as cli:
            self.assertEqual(runtime.main(), 23)
        self.assertEqual(cli.call_args.args[-1], ["--agent", "--repo"])

    def test_cli_refuses_to_start_without_the_launch_value_options(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--warn-bytes", "1", "--", "exec", "kiro-cli"]), \
                patch.object(runtime, "cli") as cli, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            runtime.main()
        cli.assert_not_called()


if __name__ == "__main__":
    unittest.main()

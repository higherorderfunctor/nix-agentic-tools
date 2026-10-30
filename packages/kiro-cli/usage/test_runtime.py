"""Offline launch summaries use exact identity and preserve command behavior."""
# cspell:words preexec TIOCSCTTY
import base64
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

from capture import Collector, lock_beside
import disk_index
from mitm_addon import UsageCapture
import runtime


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
            self.assertIn("Kiro usage · sess_selected · tree · 1 request", output.getvalue())
            self.assertNotIn("sess_other", output.getvalue())
            self.assertIn("\n⚠ credits unknown for 1/1 request; 1 incomplete; calls with no conversation identity excluded\n", output.getvalue())
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "c" * 32, 1 << 30)
            self.assertIn("unavailable", output.getvalue())
            self.assertNotIn("Kiro usage ·", output.getvalue())

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

    def test_summary_warns_past_the_payload_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            collector.finish(collector.begin({"invocation": "a" * 32}, b'{"metadata":{"kiro:conversation_id":"sess_selected"}}'))
            collector.close()
            for threshold, warned in ((collector.stored_bytes - 1, True), (collector.stored_bytes, False)):
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    runtime.invocation_summary(root, "a" * 32, threshold)
                self.assertEqual("archive or delete " + str(root / "usage.sqlite3") in output.getvalue(), warned)
                self.assertIn("Kiro usage · sess_selected", output.getvalue())

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
            self.assertEqual(output.getvalue().count("Kiro usage · sess_root · tree · 2 requests"), 1)
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
                    self.assertIn("Kiro usage · sess_auto · tree · 1 request · — credits", output.getvalue())  # disk credits stay out

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
            with patch.dict(os.environ, {"HOME": str(root)}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(disk_index, "MTIME_SLACK_NS", 0), patch.object(runtime, "wait_command", side_effect=self.writing_child(0, write)), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "invocation_summary", wraps=runtime.invocation_summary) as summary, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 1)
            self.assertTrue(summary.call_args.kwargs["disk_refreshed"])

    def test_unsettled_wait_is_not_a_clean_refresh(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_open"}}).encode())
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=0), patch.object(runtime, "refresh_disk_index", return_value=True), patch.object(runtime.uuid, "uuid4", return_value=SimpleNamespace(hex="a" * 32)), patch.object(runtime, "SETTLE_TIMEOUT", .3), patch.object(runtime, "invocation_summary", wraps=runtime.invocation_summary) as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root, 19001, 1 << 30, ["kiro-cli", "chat"]), 0)
            self.assertIn("capture writer still has unfinished calls", output.getvalue())
            self.assertFalse(summary.call_args.kwargs["disk_refreshed"])

    def test_call_finishing_after_wait_timeout_keeps_unfinished_warning(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            collector = Collector(root / "usage.sqlite3")
            self.addCleanup(collector.close)
            ident = collector.begin({"invocation": "a" * 32}, json.dumps({"metadata": {"kiro:conversation_id": "sess_late"}}).encode())
            def refresh(*_):
                collector.finish(ident)  # finishes after the wait timed out, before the summary reads
                with sqlite3.connect(root / "usage.sqlite3") as db:
                    while db.execute("SELECT state FROM captures WHERE id=?", (ident,)).fetchone()[0] == "recording":
                        time.sleep(.01)
                db.close()
                return True
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

    def test_refresh_skips_while_full_index_holds_lock(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            collector.finish(collector.begin({}, json.dumps({"metadata": {"kiro:conversation_id": "sess_auto"}}).encode()))
            collector.close()
            session = root / ".kiro/sessions/workspace/sess_auto"
            session.mkdir(parents=True)
            (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": []}}) + "\n")
            held = lock_beside(state / "usage.sqlite3", disk_index.INDEX_LOCK, blocking=True)
            try:
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    self.assertFalse(runtime.refresh_disk_index(state, 0))
            finally:
                os.close(held)
            self.assertEqual(output.getvalue().count("\n"), 1)
            self.assertIn("full Kiro session index is running", output.getvalue())
            with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='disk_records'").fetchone())
            self.assertTrue(runtime.refresh_disk_index(state, 0))
            held = lock_beside(state / "usage.sqlite3", disk_index.INDEX_LOCK, shared=True)  # a concurrent launch's exit refresh
            try:
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    self.assertTrue(runtime.refresh_disk_index(state, 0))
            finally:
                os.close(held)
            self.assertEqual(output.getvalue(), "")

    def test_concurrent_refreshes_queue_instead_of_racing(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            state = root / "state"
            collector = Collector(state / "usage.sqlite3")
            collector.finish(collector.begin({}, json.dumps({"metadata": {"kiro:conversation_id": "sess_auto"}}).encode()))
            collector.close()
            session = root / ".kiro/sessions/workspace/sess_auto"
            session.mkdir(parents=True)
            (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": []}}) + "\n")
            held = lock_beside(state / "usage.sqlite3", disk_index.REFRESH_LOCK, blocking=True)  # another launch's refresh mid-scan
            results = []
            try:
                with contextlib.redirect_stderr(io.StringIO()) as output:
                    thread = threading.Thread(target=lambda: results.append(runtime.refresh_disk_index(state, 0)))
                    thread.start()
                    thread.join(.5)
                    self.assertTrue(thread.is_alive())  # waits rather than reading the same offset concurrently
                    with contextlib.closing(sqlite3.connect(state / "usage.sqlite3")) as db:
                        self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='disk_records'").fetchone())
            finally:
                os.close(held)
            thread.join(10)
            self.assertEqual(results, [True])
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(os.stat(str(state / "usage.sqlite3") + disk_index.REFRESH_LOCK).st_mode & 0o777, 0o600)

    def test_index_missing_tree_and_failure_are_nonfatal(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}, clear=True):
            root = Path(directory)
            self.assertFalse(runtime.refresh_disk_index(root / "missing", 0))
            self.assertFalse((root / "missing").exists())
            sessions = root / ".kiro/sessions"
            sessions.parent.mkdir()
            sessions.write_text("not a directory")
            with patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "invocation_summary") as summary, contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(runtime.exec_command(root / "state", 19001, 1 << 30, ["kiro-cli", "chat"]), 23)
            self.assertIn("automatic Kiro session indexing failed", output.getvalue())
            self.assertFalse(summary.call_args.kwargs["disk_refreshed"])

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
        with patch.dict(os.environ, {"KIRO_USAGE_INVOCATION": "a" * 32}), patch.object(runtime, "launch_environment", return_value={}) as environment, patch.object(os, "execvpe") as execute, patch.object(runtime, "refresh_disk_index", return_value=False) as refresh, patch.object(runtime, "invocation_summary") as summary:
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
                script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.refresh_disk_index=lambda *a: False; runtime.invocation_summary=lambda *a, **kw: print('summary', file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, 1 << 30, [{str(executable)!r}]))"
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

    def test_non_chat_commands_skip_summary(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "refresh_disk_index", return_value=False), patch.object(runtime, "invocation_summary") as summary:
            for arguments in (["--version"], ["--help"], ["login"], ["--help-all"], ["chat", "--help"], ["--agent-engine", "v3", "login"], ["--agent-engine=v3", "whoami"], ["--tui", "login"], ["--agent", "x", "mcp", "list"]):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments])
            self.assertEqual(execute.call_count, 9)
            summary.assert_not_called()
            wait.assert_not_called()
            for arguments in (["chat", "please explain login and --version"], ["chat", "--", "--help"], ["--resume-id", "sess_resume"], ["--agent", "doctor"], ["--model", "login"], []):
                runtime.exec_command(Path("/unused"), 19001, 1 << 30, ["kiro-cli", *arguments])
            self.assertEqual(summary.call_count, 6)

    def test_closed_summary_stderr_keeps_child_status(self):
        for status, expected in ((23, 23), (-signal.SIGTERM, -signal.SIGTERM)):
            script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.wait_command=lambda *a: {status}; runtime.refresh_disk_index=lambda *a: False; runtime.invocation_summary=lambda *a, **kw: print('summary',file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, 1 << 30, ['kiro-cli','chat']))"
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
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "refresh_disk_index", return_value=False), patch.object(runtime, "invocation_summary", side_effect=interrupt):
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

    def test_session_summary_alone_receives_the_summary_theme(self):
        query = str(Path(runtime.__file__).parent / "query.py")
        for tail, styled in ((["--summary"], ["--summary-theme", "/theme.json"]), (["--json"], [])):
            with patch.object(runtime, "private_directory"), patch.object(os, "execv") as execute:
                runtime.cli(Path("/state"), ["session", "sess_root", *tail], 19001, 1 << 30, "/theme.json")
            execute.assert_called_once_with(sys.executable, [sys.executable, query, "--db", "/state/usage.sqlite3",
                                                             "--session", "sess_root", *tail, *styled])

    def test_main_returns_child_status(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--warn-bytes", "1", "--", "exec", "kiro-cli"]), patch.object(runtime, "cli", return_value=23):
            self.assertEqual(runtime.main(), 23)


if __name__ == "__main__":
    unittest.main()

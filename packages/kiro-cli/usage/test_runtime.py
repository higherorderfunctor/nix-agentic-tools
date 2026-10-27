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
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from capture import Collector
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
                runtime.invocation_summary(root, "a" * 32, timeout=0)
            self.assertIn("Session: sess_selected", output.getvalue())
            self.assertNotIn("sess_other", output.getvalue())
            self.assertIn("full session totals", output.getvalue())
            self.assertIn("no conversation identity", output.getvalue())
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "c" * 32, timeout=0)
            self.assertIn("unavailable", output.getvalue())
            self.assertNotIn("Session:", output.getvalue())

    def test_read_only_missing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with contextlib.redirect_stderr(io.StringIO()) as output:
                runtime.invocation_summary(root, "a" * 32, timeout=0)
            self.assertIn("unavailable", output.getvalue())
            self.assertFalse((root / "usage.sqlite3").exists())

    def test_nested_launch_reuses_marker_and_skips_summary(self):
        with patch.dict(os.environ, {"KIRO_USAGE_INVOCATION": "a" * 32}), patch.object(runtime, "launch_environment", return_value={}) as environment, patch.object(os, "execvpe") as execute, patch.object(runtime, "invocation_summary") as summary:
            runtime.exec_command(Path("/unused"), 19001, ["kiro-cli", "chat"])
            environment.assert_called_once_with(Path("/unused"), 19001, refuse_conflicts=False, invocation="a" * 32)
            execute.assert_called_once_with("kiro-cli", ["kiro-cli", "--v3", "chat"], {})
            summary.assert_not_called()

    def test_supervised_child_status_stdout_and_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "kiro-cli"
            for body, expected in (("print('machine stdout'); raise SystemExit(23)", 23), ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -signal.SIGTERM), ("import os, signal; os.kill(os.getpid(), signal.SIGKILL)", -signal.SIGKILL)):
                executable.write_text(f"#!{sys.executable}\n" + body + "\n")
                executable.chmod(0o700)
                script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.invocation_summary=lambda *a: print('summary', file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, [{str(executable)!r}]))"
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
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "invocation_summary") as summary:
            for arguments in (["--version"], ["--help"], ["login"], ["--help-all"], ["chat", "--help"], ["--agent-engine", "v3", "login"], ["--agent-engine=v3", "whoami"], ["--tui", "login"], ["--agent", "x", "mcp", "list"]):
                runtime.exec_command(Path("/unused"), 19001, ["kiro-cli", *arguments])
            self.assertEqual(execute.call_count, 9)
            summary.assert_not_called()
            wait.assert_not_called()
            for arguments in (["chat", "please explain login and --version"], ["chat", "--", "--help"], ["--resume-id", "sess_resume"], ["--agent", "doctor"], ["--model", "login"], []):
                runtime.exec_command(Path("/unused"), 19001, ["kiro-cli", *arguments])
            self.assertEqual(summary.call_count, 6)

    def test_closed_summary_stderr_keeps_child_status(self):
        for status, expected in ((23, 23), (-signal.SIGTERM, -signal.SIGTERM)):
            script = f"import runtime; from pathlib import Path; runtime.launch_environment=lambda *a, **kw: dict(runtime.os.environ); runtime.wait_command=lambda *a: {status}; runtime.invocation_summary=lambda *a: print('summary',file=runtime.sys.stderr); raise SystemExit(runtime.exec_command(Path('/unused'), 19001, ['kiro-cli','chat']))"
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
        def interrupt(*arguments):
            os.kill(os.getpid(), signal.SIGINT)
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "launch_environment", return_value={}), patch.object(runtime, "wait_command", return_value=23), patch.object(runtime, "invocation_summary", side_effect=interrupt):
            self.assertEqual(runtime.exec_command(Path("/unused"), 19001, ["kiro-cli", "chat"]), 23)

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

    def test_main_returns_child_status(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--", "exec", "kiro-cli"]), patch.object(runtime, "cli", return_value=23):
            self.assertEqual(runtime.main(), 23)


if __name__ == "__main__":
    unittest.main()

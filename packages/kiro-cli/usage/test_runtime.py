"""Offline launch summaries use exact identity and preserve command behavior."""
# cspell:words preexec TIOCSCTTY
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
from unittest.mock import patch

from capture import Collector
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
        master, slave = pty.openpty()
        script = "import runtime,sys; code=\"import os,signal,time; print('TTY', *(os.isatty(n) for n in (0,1,2)), flush=True); signal.signal(signal.SIGINT, lambda *a: (print('INT',flush=True), time.sleep(.1), sys.exit(0))); time.sleep(20)\"; code='import sys; '+code; result=runtime.wait_command(sys.executable, ['-c',code], dict(runtime.os.environ)); print('EXIT',result,flush=True)"
        process = subprocess.Popen([sys.executable, "-c", script], cwd=Path(__file__).parent,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                                   preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
        os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 5
            while b"TTY True True True" not in output:
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
            os.close(master)

    def test_main_returns_child_status(self):
        with patch.object(sys, "argv", ["runtime.py", "cli", "--port", "19001", "--", "exec", "kiro-cli"]), patch.object(runtime, "cli", return_value=23):
            self.assertEqual(runtime.main(), 23)


if __name__ == "__main__":
    unittest.main()

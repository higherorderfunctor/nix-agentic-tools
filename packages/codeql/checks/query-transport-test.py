"""Exercise concurrent inline publication and shutdown with incomplete requests."""

import concurrent.futures
import importlib.machinery
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
from unittest import mock

cli = sys.argv[1]
module = types.ModuleType("codeql_query")
importlib.machinery.SourceFileLoader(module.__name__, cli).exec_module(module)

# A live publication can already point its engine at the next generation.
# Resolve the DB once and prefer that generation's engine; retain old aliases.
with tempfile.TemporaryDirectory(prefix="cq-generation-") as temporary:
    root = Path(temporary)
    generation, live = root / "generation", root / "live"
    (generation / "db").mkdir(parents=True)
    live.mkdir()
    (live / "db").symlink_to(generation / "db")
    for parent in (generation, live):
        (parent / "engine/bin").mkdir(parents=True)
        executable = parent / "engine/bin/codeql"
        executable.write_text("")
        executable.chmod(0o700)
    assert module.resolve_database(live / "db") == (generation / "db", str(generation / "engine/bin/codeql"))
    (generation / "engine/bin/codeql").unlink()
    assert module.resolve_database(live / "db") == (generation / "db", str(live / "engine/bin/codeql"))
    print("generation engine wins over live engine; legacy plain-directory alias remains supported")

# Pause a real file write after open() exposes an empty inode. The other caller
# must reach the compiler with both complete files while that writer is paused.
for filename in ("qlpack.yml", "Query.ql"):
    with tempfile.TemporaryDirectory(prefix="cq-publish-") as temporary:
        root = Path(temporary)
        opened, release = threading.Event(), threading.Event()
        original_write = Path.write_text
        compiler_inputs = []
        expression = "select 1"
        manifest = {"name": "local/inline-query", "version": "0.0.0", "dependencies": {"test/nix-all": "*"}}

        def delayed_write(path, content, *args, **kwargs):
            if path.name == filename and threading.current_thread().name.startswith("publisher"):
                with path.open("w") as stream:
                    opened.set()
                    assert release.wait(10), "publisher was not released"
                    return stream.write(content)
            return original_write(path, content, *args, **kwargs)

        def command(argv):
            if argv[1:3] == ["resolve", "database"]:
                return json.dumps({"languages": ["nix"]})
            if argv[1:3] == ["resolve", "qlpacks"]:
                return json.dumps({"test/nix-all": []})
            assert argv[1:3] == ["query", "run"], argv
            query = Path(argv[3])
            observed = (query.read_text(), json.loads((query.parent / "qlpack.yml").read_text()))
            assert observed == (expression, manifest), observed
            compiler_inputs.append(observed)
            return ""

        args = types.SimpleNamespace(database=str(root), expression=expression,
                                     no_daemon=True, ram=6000, sort_key="0", threads=4)
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(root)}), \
             mock.patch.object(module, "resolve_database", return_value=(root, "engine")), \
             mock.patch.object(module, "command", side_effect=command), \
             mock.patch.object(module, "decode", return_value={"tuples": [[1]]}), \
             mock.patch.object(Path, "write_text", delayed_write), \
             concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="publisher") as pool:
            first = pool.submit(module.run, args)
            try:
                assert opened.wait(5), "first publisher did not start"
                module.run(args)
            finally:
                release.set()
            first.result(timeout=5)
        assert len(compiler_inputs) == 2
        print(f"atomic first-use {filename}: both fallback callers received complete files")

# Keep idle and partial clients connected until after SIGTERM has completed.
with tempfile.TemporaryDirectory(prefix="cq-stop-") as temporary:
    root = Path(temporary)
    path = root / "run/query.sock"
    daemon = subprocess.Popen([sys.executable, cli, "--socket", str(path), "serve",
                               "--state-dir", str(root / "state")], stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 5
        while not path.exists():
            assert daemon.poll() is None, daemon.stderr.read()
            assert time.monotonic() < deadline, "daemon did not publish its socket"
            time.sleep(0.01)
        with socket.socket(socket.AF_UNIX) as idle, socket.socket(socket.AF_UNIX) as partial:
            idle.connect(str(path))
            partial.connect(str(path))
            partial.sendall(b'{"database":')
            # A full request proves the accept loop has passed both pending clients.
            with socket.socket(socket.AF_UNIX) as complete:
                complete.connect(str(path))
                complete.sendall(b"{}\n")
                with complete.makefile("rb") as stream:
                    assert "database" in json.loads(stream.readline())["error"]
            daemon.terminate()
            _, error = daemon.communicate(timeout=5)
            assert daemon.returncode == 0, error
            assert not path.exists(), "shutdown left the socket"
            assert not error, error
        print("SIGTERM with accepted idle and partial clients: exit 0, socket removed")
    finally:
        if daemon.poll() is None:
            daemon.kill()
            daemon.communicate()

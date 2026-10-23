"""Exercise the actual CLI, daemon and 2.27.3 server over two tiny Nix DBs."""

import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import shutil
import socket as socket_module
import subprocess
import sys
import tempfile
import time

cli, engine, creator, fixture = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="cq-") as temporary, contextlib.ExitStack() as clients:
    root = Path(temporary)
    os.environ["XDG_CACHE_HOME"] = str(root / "cache")
    source = root / "source"
    shutil.copytree(fixture, source)
    source.chmod(0o700)
    first, second = root / "one", root / "two"
    for state in (first, second):
        if state == second:
            (source / "extra.nix").write_text('{ extra = 1; }\n')
        subprocess.run([creator, str(state), str(source)], check=True)
        (state / "engine").symlink_to(engine)
    checkout = root / "checkout"
    live = checkout / ".devenv/state/codeql/nix"
    live.mkdir(parents=True)
    (checkout / "nested").mkdir()
    (live / "db").symlink_to(first / "db")
    (live / "engine").symlink_to(engine)
    pack = root / "pack"
    pack.mkdir()
    (pack / "qlpack.yml").write_text(json.dumps({"name": "test/query", "version": "0.0.0", "dependencies": {"jamiemagee/nix-all": "*"}}))
    query = pack / "Count.ql"
    text = "import codeql.nix.Nix\nselect count(NIX::Binding b)\n"
    query.write_text(text)
    socket = root / "run/query.sock"
    base = [cli, "--socket", str(socket)]
    measurements = []

    def run(label, database=live, *options):
        start = time.monotonic()
        result = subprocess.run([*base, "run", *options, str(database), str(query)], capture_output=True, text=True)
        measurements.append({"label": label, "seconds": round(time.monotonic() - start, 3), "exit": result.returncode})
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    expected = run("fallback")
    daemon = subprocess.Popen([*base, "serve", "--state-dir", str(root / "state"), "--idle-seconds", "20"], stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while not socket.exists():
            assert daemon.poll() is None, daemon.stderr.read()
            assert time.monotonic() < deadline
            time.sleep(0.05)
        assert run("daemon-cold") == expected
        assert run("daemon-warm") == expected
        named = subprocess.run([*base, "run", "nix", str(query)], cwd=checkout / "nested", capture_output=True, text=True, check=True)
        assert json.loads(named.stdout) == expected
        sorted_query = pack / "Sorted.ql"
        sorted_query.write_text("import codeql.nix.Nix\nfrom int n where n in [3, 1, 2] select n\n")
        sorted_result = subprocess.run([*base, "run", str(live), str(sorted_query)], capture_output=True, text=True, check=True)
        assert json.loads(sorted_result.stdout)["tuples"] == [[1], [2], [3]]
        other = run("second-cold", second)
        assert other != expected, "fixture must change the query's result"
        assert run("first-after-second") == expected
        with concurrent.futures.ThreadPoolExecutor() as pool:
            a = pool.submit(run, "concurrent-first")
            b = pool.submit(run, "concurrent-second", second)
            assert a.result() == expected and b.result() == other
        inline = subprocess.run([*base, "run", str(live), "-e", text], capture_output=True, text=True, check=True)
        assert json.loads(inline.stdout) == expected
        # A new query text exercises incremental compilation in the warm JVM.
        query.write_text(text.replace("count(NIX::Binding b)", "count(NIX::Binding b) + 1"))
        changed = run("edited-query")
        assert changed != expected
        query.write_text(text)
        bad = pack / "Broken.ql"
        bad.write_text("import codeql.nix.Nix\nselect missingFunction()\n")
        result = subprocess.run([*base, "run", str(live), str(bad)], capture_output=True, text=True)
        assert result.returncode != 0 and "Broken.ql" in result.stderr and "2" in result.stderr, result.stderr
        print("compile-error:", result.stderr.strip())
        assert run("after-compile-error") == expected
        swap = live / "next"
        swap.symlink_to(second / "db")
        swap.replace(live / "db")
        assert run("new-generation") == other
        # The old generation must be usable by another CodeQL process now.
        assert run("released-old-generation", first, "--no-daemon") == expected
        # The daemon has no evaluation children after its idle deadline.
        time.sleep(22)
        children = Path(f"/proc/{daemon.pid}/task/{daemon.pid}/children").read_text().strip()
        assert children == "", f"idle query servers survived: {children}"
        print("idle-children:", repr(children))
        assert run("after-idle") == other
        for payload in (b"", b'{"database":'):
            client = clients.enter_context(socket_module.socket(socket_module.AF_UNIX))
            client.connect(str(socket))
            client.sendall(payload)
        assert run("after-incomplete-clients") == other
    finally:
        daemon.terminate()
        _, error = daemon.communicate(timeout=30)
        assert daemon.returncode == 0, error
        assert not socket.exists(), "shutdown left a socket"
    print(json.dumps(measurements, indent=2))

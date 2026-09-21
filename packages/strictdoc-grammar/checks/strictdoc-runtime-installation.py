"""Installed toolchain deployment smoke, independent of the repository corpus."""

import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

GENERATE, DAEMON, PROJECT_SCRIBE, PROJECT_BOARD = sys.argv[1:5]


def run(*argv, env, cwd, ok=True):
    result = subprocess.run(argv, env=env, cwd=cwd, text=True, capture_output=True, timeout=30)
    if (result.returncode == 0) != ok:
        raise AssertionError(f"{argv}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def client(root, verb, *, env, cwd, **kwargs):
    result = run("scribe-client", "--root", str(root), verb, env=env, cwd=cwd, **kwargs)
    return json.loads(result.stdout)


def prepare(root, *, env, cwd):
    root.mkdir()
    (root / "strictdoc_config.py").write_text(
        "from strictdoc.core.project_config import ProjectConfig\n"
        "def create_config():\n"
        "    return ProjectConfig(project_title='Deployment smoke', "
        "grammars={'@repo': 'grammar.sgra'})\n"
    )
    project_env = env | {"DEVENV_ROOT": str(root)}
    run(GENERATE, env=project_env, cwd=cwd)
    grammar = root / "grammar.sgra"
    before = (grammar.read_bytes(), grammar.stat().st_mtime_ns)
    run(GENERATE, env=project_env, cwd=cwd)
    assert before == (grammar.read_bytes(), grammar.stat().st_mtime_ns)
    (root / "seed.sdoc").write_text(
        "[DOCUMENT]\nTITLE: Deployment smoke\n\n"
        "[GRAMMAR]\nIMPORT_FROM_FILE: @repo\n"
    )
    return project_env


@contextlib.contextmanager
def daemon(root, *, env, cwd):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([DAEMON], env=env, cwd=cwd, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    break
                ready = subprocess.run(
                    ["scribe-client", "--root", str(root), "ping"],
                    env=env, cwd=cwd, text=True, capture_output=True, timeout=5,
                )
                if ready.returncode == 0:
                    yield proc
                    return
                time.sleep(0.05)
            log.seek(0)
            raise AssertionError(f"daemon did not become ready:\n{log.read()}")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
                    raise AssertionError("daemon did not shut down")


def smoke(base):
    # Environment comes from the module's Nix packages, not the developer shell.
    env = {key: value for key, value in os.environ.items()
           if key not in {"DEVENV_ROOT", "PYTHONPATH", "SCRIBE_ROOT", "STRICTDOC_CACHE_DIR"}}
    with tempfile.TemporaryDirectory(prefix="scribe-runtime-") as runtime:
        env["XDG_RUNTIME_DIR"] = runtime
        first, second = base / "first", base / "second"
        first_env = prepare(first, env=env, cwd=base)
        second_env = prepare(second, env=env, cwd=base)
        missing = run("scribe", "--root", str(first), "list", env=env, cwd=base, ok=False)
        assert "daemon" in missing.stderr.lower() and "Traceback" not in missing.stderr

        # All three entry points are installed and share one filtered source.
        sources = set()
        for name in ("scribe", "scribe-client", "scribe-daemon"):
            wrapper = Path(shutil.which(name)).read_text()
            match = re.search(r"script=(/nix/store/[^\s]+/scribe_[a-z]+\.py)", wrapper)
            assert match, (name, wrapper)
            sources.add(Path(match[1]).parent)
        assert len(sources) == 1
        source = sources.pop()
        files = [p.relative_to(source) for p in source.rglob("*") if p.is_file()]
        assert files and all(p.suffix == ".py" for p in files)
        assert not any("semantics" in str(p) or "board" in str(p) or "model.json" in str(p) for p in files)
        assert not (first / "dev").exists() and not (second / "dev").exists()
        assert shutil.which("sdoc-board") is None

        with daemon(first, env=first_env, cwd=base), daemon(second, env=second_env, cwd=base):
            for root, uid in ((first, "ITEM-FIRST"), (second, "ITEM-SECOND")):
                run("scribe", "--root", str(root), "new", "ITEM", "--uid", uid,
                    "--title", uid, "--statement", "Installed writer", "--path", "item.sdoc",
                    env=env, cwd=base)
                assert (root / "item.sdoc").is_file()
                info = client(root, "info", env=env, cwd=base)
                assert info["root"] == str(root) and info["nodes"] == 1
                client(root, "reload", env=env, cwd=base)
                shown = run("scribe", "--root", str(root), "show", uid, env=env, cwd=base)
                assert "Installed writer" in shown.stdout
                assert "AUTHORED_BY: llm" in shown.stdout
                other_uid = "ITEM-SECOND" if root == first else "ITEM-FIRST"
                listing = run("scribe", "--root", str(root), "list", env=env, cwd=base)
                assert uid in listing.stdout and other_uid not in listing.stdout

            sockets = list((Path(runtime) / "scribe").glob("*.sock"))
            assert len(sockets) == 2
            second_socket = next(path for path in sockets if path.name.startswith("second-"))
            wrong = run("scribe-client", "--root", str(first), "--socket", str(second_socket),
                        "info", env=env, cwd=base, ok=False)
            assert "another workspace" in wrong.stderr

            guarded = run("scribe", "--root", str(first), "set", "ITEM-FIRST",
                          "--authored-by", "human", env=env, cwd=base, ok=False)
            assert "operator" in guarded.stderr and "Traceback" not in guarded.stderr
            unavailable = run("scribe", "--root", str(first), "semantics", env=env, cwd=base, ok=False)
            assert "semantics engine is unavailable" in unavailable.stderr
            assert "Traceback" not in unavailable.stderr
            # A broken optional import must not break ordinary verbs.
            broken = base / "broken"
            (broken / "sdoc_semantics").mkdir(parents=True)
            (broken / "sdoc_semantics" / "__init__.py").write_text("raise ValueError('smoke broken engine')\n")
            broken_env = env | {"PYTHONPATH": str(broken)}
            refused = run("scribe", "--root", str(first), "semantics", env=broken_env, cwd=base, ok=False)
            assert "smoke broken engine" in refused.stderr and "Traceback" not in refused.stderr
            run("scribe", "--root", str(first), "set", "ITEM-FIRST", "--title", "Changed",
                env=broken_env, cwd=base)
            before = client(first, "info", env=env, cwd=base)["generation"]
            path = first / "item.sdoc"
            path.write_text(path.read_text().replace("Changed", "Reloaded"))
            reloaded = client(first, "reload", env=env, cwd=base)
            assert reloaded["generation"] > before
            shown = run("scribe", "show", "ITEM-FIRST", env=env | {"SCRIBE_ROOT": str(first)}, cwd=base)
            assert "Reloaded" in shown.stdout
            # cwd discovery resolves the same root from a child directory.
            nested = first / "nested"
            nested.mkdir()
            run("scribe", "show", "ITEM-FIRST", env=env, cwd=nested)

            # PREFIX is optional in the public grammar surface. Missing and
            # empty prefixes neither constrain new UIDs nor own every UID.
            for tag, uid in (("EMPTY", "free-empty"), ("UNPREFIXED", "free-absent")):
                run("scribe", "--root", str(first), "new", tag, "--uid", uid,
                    "--title", uid, "--path", uid + ".sdoc", env=env, cwd=base)
                client(first, "reload", env=env, cwd=base)
                shown = run("scribe", "--root", str(first), "show", uid, env=env, cwd=base)
                assert f"UID: {uid}" in shown.stdout
            checked = run("scribe", "--root", str(first), "check", env=env, cwd=base)
            assert "3 nodes, 0 finding(s)" in checked.stdout, checked.stdout
            assert "NOTE " not in checked.stdout
            refused = run("scribe", "--root", str(first), "new", "ITEM", "--uid", "wrong",
                          "--title", "Wrong prefix", "--path", "wrong.sdoc",
                          env=env, cwd=base, ok=False)
            assert "prefix 'ITEM-'" in refused.stderr
            assert not (first / "wrong.sdoc").exists()
        assert not list((Path(runtime) / "scribe").glob("*.sock"))

        # Project mode keeps live source resolution. Synthetic entry points
        # verify delivery only; no repository semantics or board is imported.
        development = base / "development"
        development.mkdir()
        (development / "strictdoc_config.py").touch()
        for program, relative in ((PROJECT_SCRIBE, "dev/scripts/scribe_cmd.py"),
                                  (PROJECT_BOARD, "docs/sdoc/board/server.py")):
            entry = development / relative
            entry.parent.mkdir(parents=True, exist_ok=True)
            entry.write_text("import sys; print('live-one', sys.argv[1])\n")
            first_run = run(program, "argument", env=env, cwd=development)
            assert first_run.stdout.strip() == "live-one argument"
            entry.write_text("import sys; print('live-two', sys.argv[1])\n")
            second_run = run(program, "argument", env=env, cwd=development)
            assert second_run.stdout.strip() == "live-two argument"

        # Failed default-config hydration must replay captured Unicode chatter
        # and report the original exception, rather than another fileno error.
        bad = base / "bad"
        bad.mkdir()
        (bad / "strictdoc_config.py").write_text(
            "from strictdoc.core.project_config import ProjectConfig\n"
            "def create_config():\n"
            "    ProjectConfig()\n"
            "    print('configuration diagnostic é')\n"
            "    raise ValueError('deliberate config error')\n"
        )
        failed = run(DAEMON, env=env | {"DEVENV_ROOT": str(bad)}, cwd=base, ok=False)
        assert "configuration diagnostic é" in failed.stderr
        assert "deliberate config error" in failed.stderr and "fileno" not in failed.stderr

    print("installed StrictDoc runtime: source boundary, generation, writes, reload, root/socket isolation, guards and optional semantics passed")


with tempfile.TemporaryDirectory(prefix="strictdoc-install-", dir=os.environ.get("SDOC_SMOKE_BASE")) as directory:
    smoke(Path(directory).resolve())

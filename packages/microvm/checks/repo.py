# cspell:ignore gethostname objectname refspec
"""Run production repository preparation, clone, and export with a QEMU stub.

The stub resolves the two shares locally. Read-only mount enforcement needs the
separate microvm-sandbox-repo-root-launcher hand boot.
"""

import fcntl
import json
import os
import shlex
import socket
from pathlib import Path
import subprocess
import sys
import tempfile


def git(*args, cwd, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check, text=True, capture_output=True)


def output(*args, cwd):
    return git(*args, cwd=cwd).stdout.strip()


def runner():
    runtime = Path.cwd()
    case = json.loads(Path(os.environ["TEST_CASE"]).read_text())
    main = Path(case["main"])
    common = Path(output("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=main))
    for publication_lock in [common / "gc.pid", common / "gc.pid.lock", common / "objects/maintenance.lock"]:
        assert not publication_lock.exists(), publication_lock
    seed = runtime / "seed"
    assert (runtime / "objects").is_symlink()
    assert (runtime / "objects").resolve() == common / "objects"
    assert seed.is_dir() and not seed.is_symlink()
    assert (seed / "objects/info/alternates").read_text() == "/mnt/objects\n"
    assert (runtime / "repo-head").read_text() == case["head"]
    assert (runtime / "repo-branch").read_text() == case["branch"]
    assert output("--git-dir", str(seed), "rev-parse", "--show-object-format", cwd=main) == case["format"]
    assert not (seed / "hooks").exists()
    assert "host-secret" not in (seed / "config").read_text()
    # Replace the mount destination only after checking the real wire value.
    (seed / "objects/info/alternates").write_text(f"{common / 'objects'}\n")
    refs = dict(
        line.split(" ", 1)
        for line in output("--git-dir", str(seed), "for-each-ref", "--format=%(refname) %(objectname)", cwd=main).splitlines()
    )
    assert refs == case["seed_refs"], (refs, case["seed_refs"])
    roots = (runtime / "seed-roots").read_text().splitlines()
    assert roots == sorted(set(case["seed_refs"].values())), roots
    pins = output("for-each-ref", "--format=%(refname) %(objectname)", "refs/sandbox/", cwd=main)
    assert all(any(line.endswith(" " + root) for line in pins.splitlines()) for root in roots)
    assert "refs/sandbox/" + "a" * 32 not in pins
    if case.get("active_lock"):
        assert "refs/sandbox/" + "b" * 32 in pins
    if case["mode"] == "gc":
        # Remove every original reference to both borrowed roots. The current
        # worktree's detached HEAD must also stop retaining the borrowed commit.
        git("update-ref", "--no-deref", "HEAD", case["base"], cwd=case["worktree"])
        for ref in case["delete_refs"]:
            git("update-ref", "-d", ref, cwd=main)
        git("reflog", "expire", "--expire=now", "--all", cwd=main)
        git("gc", "--prune=now", cwd=main)
        for root in roots:
            git("cat-file", "-e", root + "^{commit}", cwd=main)
    clone = Path(case["clone"])
    guest = Path(case["guest"])
    result = subprocess.run([str(guest), "uncommitted"], text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print(result.stdout, end="", flush=True)
    report = dict(line.split("=", 1) for line in result.stdout.splitlines() if line.startswith("REPO_") and not line.startswith("REPO_REF="))
    assert report["REPO_PWD"] == str(clone)
    assert report["REPO_HEAD"] == case["head"]
    assert report["REPO_BRANCH"] == case["branch"]
    assert report["REPO_HOST_ONLY"] == "absent"
    assert report["REPO_STATUS_LINES"] == "0"
    if case["head"]:
        assert (clone / "file").read_text() == "committed\n"
        git("fsck", "--no-dangling", cwd=clone)
    committed_export = case["mode"] in ("malformed-ref", "recover", "truncated-pack")
    if committed_export:
        git("commit", "--quiet", "--allow-empty", "-m", "guest-only", cwd=clone)
        recovered = output("rev-parse", "HEAD", cwd=clone)
        # A push or fetch can advance origin to the guest commit without the
        # host learning it. Only immutable seeded roots are valid exclusions.
        git("update-ref", "refs/remotes/origin/advanced", recovered, cwd=clone)
        Path(case["recovered"]).write_text(recovered)
    if case["mode"] == "invalid-bundle":
        (runtime / "bundle").write_bytes(b"truncated bundle\n")
        (runtime / "bundle-status").write_text("ok\n")
    elif case["mode"] == "export-failure":
        (runtime / "bundle-status").write_text("failed\n")
    elif case["mode"] != "missing-export":
        exported = subprocess.run([case["export"]], capture_output=True)
        assert exported.returncode in (0, 3), exported.stderr
        payload = exported.stdout
        if case["mode"] in ("malformed-ref", "truncated-pack"):
            header, pack = payload.split(b"\n\n", 1)
            if case["mode"] == "malformed-ref":
                lines = header.splitlines()
                index = next(i for i, line in enumerate(lines) if not line.startswith((b"#", b"-", b"@")))
                lines[index] = lines[index].split(b" ", 1)[0] + b" refs/heads/bad..ref"
                header = b"\n".join(lines)
            else:
                assert pack.startswith(b"PACK")
                pack = pack[: len(pack) // 2]
            payload = header + b"\n\n" + pack
            Path(case["corrupted"]).write_bytes(payload)
        (runtime / "bundle").write_bytes(payload)
        (runtime / "bundle-status").write_text("ok\n" if exported.returncode == 0 else "empty\n")
        if committed_export:
            assert exported.returncode == 0, "new guest commit was excluded by mutable origin refs"
        else:
            assert exported.returncode == 3 and not exported.stdout
    (runtime / "status").write_text("exited:0\n")
    Path(case["runtime"]).write_text(str(runtime))
    raise SystemExit(17 if case["mode"] == "runner-failure" else 0)


if len(sys.argv) == 2 and sys.argv[1] == "--runner":
    runner()
    raise SystemExit(0)

launcher, qemu_runner, guest_command, python, exporter = sys.argv[1:]

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    env = dict(
        os.environ,
        GIT_AUTHOR_DATE="2000-01-01T00:00:00Z",
        GIT_AUTHOR_EMAIL="fixture@example.invalid",
        GIT_AUTHOR_NAME="fixture",
        GIT_COMMITTER_DATE="2000-01-01T00:00:00Z",
        GIT_COMMITTER_EMAIL="fixture@example.invalid",
        GIT_COMMITTER_NAME="fixture",
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_CONFIG_NOSYSTEM="1",
        HOME=str(root),
        TMPDIR=str(root),
    )
    os.environ.update(env)
    stub = root / "runner"
    stub.write_text(f"#!{python}\nimport runpy, sys\nsys.argv = [{__file__!r}, '--runner']\nrunpy.run_path({__file__!r}, run_name='__main__')\n")
    stub.chmod(0o755)
    host = root / "host"
    source = Path(launcher).read_text()
    assert source.count(qemu_runner) == 1
    host.write_text(source.replace(qemu_runner, str(stub)).replace("/dev/kvm", str(root)))
    host.chmod(0o755)
    template = root / "host-template"
    (template / "hooks").mkdir(parents=True)
    (template / "hooks/pre-commit").write_text("host-secret-hook\n")
    hostile_config = root / "host-config"
    hostile_config.write_text(f"[init]\n\tdefaultBranch = host-secret-branch\n\ttemplateDir = {template}\n")
    counter = 0

    def setup(*, branch="topic", mode="empty", object_format="sha1", unborn=False):
        global counter
        counter += 1
        case_root = root / str(counter)
        case_root.mkdir()
        main = case_root / "main"
        main.mkdir()
        git("init", "--quiet", "--initial-branch=main", "--object-format=" + object_format, cwd=main)
        git("config", "fixture.host-secret", "must-not-reach-seed", cwd=main)
        if unborn:
            worktree = main
            head = base = ""
            branch = "main"
            refs = {}
        else:
            (main / "file").write_text("committed\n")
            git("add", "file", cwd=main)
            git("commit", "--quiet", "-m", "base", cwd=main)
            base = output("rev-parse", "HEAD", cwd=main)
            worktree = case_root / "linked"
            git("worktree", "add", "--quiet", "-b", "topic", str(worktree), cwd=main)
            git("commit", "--quiet", "--allow-empty", "-m", "linked-head", cwd=worktree)
            head = output("rev-parse", "HEAD", cwd=worktree)
            if not branch:
                git("checkout", "--quiet", "--detach", cwd=worktree)
            (worktree / "uncommitted").write_text("host only\n")
            (worktree / "file").write_text("uncommitted host changes\n")
            refs = {"refs/sandbox/head": head}
        (worktree / "sub").mkdir()
        guest = case_root / "guest"
        guest.write_text(
            Path(guest_command).read_text()
            .replace("/run/sandbox-command/", str(case_root / "runtime-link") + "/")
            .replace("/run/sandbox/seed", str(case_root / "runtime-link/seed"))
            .replace("/home/sandbox/repo", str(case_root / "clone"))
        )
        guest.chmod(0o755)
        export = case_root / "export"
        export.write_text(
            Path(exporter).read_text()
            .replace("/run/sandbox-seed-roots", str(case_root / "runtime-link/seed-roots"))
            .replace("/home/sandbox/repo", str(case_root / "clone"))
        )
        export.chmod(0o755)
        case = {
            "base": base,
            "branch": branch,
            "clone": str(case_root / "clone"),
            "corrupted": str(case_root / "corrupted"),
            "export": str(export),
            "format": object_format,
            "guest": str(guest),
            "head": head,
            "main": str(main),
            "mode": mode,
            "recovered": str(case_root / "recovered"),
            "runtime": str(case_root / "runtime"),
            "seed_refs": refs,
            "worktree": str(worktree),
        }
        return case_root, case

    def invoke(case_root, case, expected=0):
        case_file = case_root / "case.json"
        case_file.write_text(json.dumps(case))
        # The stub needs a stable path to the production launcher's random dir.
        stub_source = stub.read_text()
        marker = "import runpy, sys\n"
        stub.write_text(stub_source.replace(marker, "import runpy, sys, os, pathlib\npathlib.Path(os.environ['TEST_RUNTIME_LINK']).symlink_to(pathlib.Path.cwd())\n"))
        result = subprocess.run(
            [str(host), "--", "uncommitted"],
            cwd=Path(case["worktree"]) / "sub",
            env=dict(
                env,
                GIT_CONFIG_GLOBAL=case.get("global_config", str(hostile_config)),
                GIT_DEFAULT_HASH="sha256" if case["format"] == "sha1" else "sha1",
                TEST_CASE=str(case_file),
                TEST_RUNTIME_LINK=str(case_root / "runtime-link"),
                XDG_STATE_HOME=str(case_root / "state"),
            ),
            text=True,
            capture_output=True,
            timeout=30,
        )
        stub.write_text(stub_source)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        pins = output("for-each-ref", "--format=%(refname)", "refs/sandbox/", cwd=case["main"])
        assert pins == ("refs/sandbox/" + "b" * 32 + "/0" if case.get("active_lock") else ""), pins
        if Path(case["runtime"]).exists():
            assert not Path(Path(case["runtime"]).read_text()).exists()
        return result

    for branch, unborn, object_format in [("topic", False, "sha1"), ("", False, "sha1"), ("main", True, "sha1"), ("topic", False, "sha256")]:
        case_root, case = setup(branch=branch, unborn=unborn, object_format=object_format)
        invoke(case_root, case)
    print("PASS: linked worktree, clean shared clone, detached HEAD, unborn branch, SHA-256, isolated seed init and empty export")

    for config, selected in [
        ({"branch.topic.pushRemote": "push", "remote.pushDefault": "default", "branch.topic.remote": "upstream"}, "push"),
        ({"remote.pushDefault": "default", "branch.topic.remote": "upstream"}, "default"),
        ({"branch.topic.remote": "upstream"}, "upstream"),
        ({}, "origin"),
    ]:
        case_root, case = setup()
        for key, value in config.items():
            git("config", key, value, cwd=case["main"])
        for remote in ["default", "origin", "push", "upstream"]:
            git("update-ref", f"refs/remotes/{remote}/{remote}-branch", case["base"], cwd=case["main"])
        git("symbolic-ref", f"refs/remotes/{selected}/HEAD", f"refs/remotes/{selected}/{selected}-branch", cwd=case["main"])
        case["seed_refs"][f"refs/heads/{selected}-branch"] = case["base"]
        invoke(case_root, case)
    case_root, case = setup()
    global_config = case_root / "global-config"
    global_config.write_text(hostile_config.read_text() + "[remote]\n\tpushDefault = global-push\n")
    case["global_config"] = str(global_config)
    git("update-ref", "refs/remotes/global-push/global-branch", case["base"], cwd=case["main"])
    git("update-ref", "refs/remotes/origin/ignored", case["head"], cwd=case["main"])
    case["seed_refs"]["refs/heads/global-branch"] = case["base"]
    invoke(case_root, case)
    print("PASS: local/global push-remote precedence and copied refs exclude symbolic remote HEAD and unrelated remotes")

    case_root, case = setup(branch="", mode="gc")
    tree = output("rev-parse", "HEAD^{tree}", cwd=case["main"])
    copied = subprocess.run(["git", "commit-tree", tree, "-p", case["base"]], cwd=case["main"], input="copied-only\n", text=True, capture_output=True, check=True).stdout.strip()
    git("update-ref", "refs/remotes/origin/copied", copied, cwd=case["main"])
    case["seed_refs"]["refs/heads/copied"] = copied
    case["delete_refs"] = ["refs/heads/topic", "refs/remotes/origin/copied"]
    invoke(case_root, case)
    git("gc", "--prune=now", cwd=case["main"])
    for oid in [case["head"], copied]:
        assert git("cat-file", "-e", oid, cwd=case["main"], check=False).returncode != 0
    print("PASS: detached HEAD and copied tip survive host gc --prune=now solely through live session pins; cleanup releases both")

    case_root, case = setup()
    common = Path(output("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=case["main"]))
    locks = common / "sandbox-locks"
    locks.mkdir()
    for token in ["a" * 32, "b" * 32]:
        git("update-ref", "refs/sandbox/" + token + "/0", case["base"], cwd=case["main"])
    case["active_lock"] = True
    with (locks / ("b" * 32)).open("w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        invoke(case_root, case)
    print("PASS: stale session pins are reaped while a held session lock preserves live pins")

    def refuse_publication(case, diagnostic):
        main = Path(case["main"])
        result = subprocess.run([str(host)], cwd=Path(case["worktree"]) / "sub", env=env, text=True, capture_output=True, timeout=10)
        assert result.returncode == 2 and diagnostic in result.stderr, (result.returncode, result.stderr)
        assert not output("for-each-ref", "--format=%(refname)", "refs/sandbox/", cwd=main)
        assert not (main / ".git/gc.pid.lock").exists()
        return result

    hostname = socket.gethostname()
    stale_pid = int(Path("/proc/sys/kernel/pid_max").read_text()) + 1
    for gc_record in [f"{os.getpid()} {hostname}", f"{stale_pid} foreign-host", f"invalid-pid {hostname}"]:
        case_root, case = setup()
        common = Path(case["main"]) / ".git"
        record = common / "gc.pid"
        record.write_text(gc_record)
        refuse_publication(case, "repository GC is active or its owner is unknown")
        assert record.read_text() == gc_record
        assert not (common / "objects/maintenance.lock").exists()
    case_root, case = setup()
    common = Path(case["main"]) / ".git"
    maintenance = common / "objects/maintenance.lock"
    maintenance.write_text("existing-maintenance-owner\n")
    refuse_publication(case, "repository maintenance is active")
    assert maintenance.read_text() == "existing-maintenance-owner\n"
    assert not (common / "gc.pid").exists()
    case_root, case = setup()
    common = Path(case["main"]) / ".git"
    (common / "gc.pid").write_text(f"{stale_pid} {hostname}")
    invoke(case_root, case)
    assert not any(path.exists() for path in [common / "gc.pid", common / "gc.pid.lock", common / "objects/maintenance.lock"])
    print("PASS: live/foreign/malformed GC owners and active maintenance refuse within ten seconds without replacing locks; stale local GC is reaped and publication locks end before QEMU")

    case_root, case = setup()
    common = Path(case["main"]) / ".git"
    blob = output("rev-parse", "HEAD:file", cwd=case["main"])
    (common / "objects" / blob[:2] / blob[2:]).unlink()
    refuse_publication(case, "a borrowed object was removed before retention")
    assert not any(path.exists() for path in [common / "gc.pid", common / "gc.pid.lock", common / "objects/maintenance.lock"])
    print("PASS: missing reachable blob refuses before VM startup and cleans session pins and publication locks")

    for branch, unborn in [("topic", False), ("", False), ("main", True)]:
        case_root, case = setup(branch=branch, unborn=unborn, mode="recover")
        result = invoke(case_root, case)
        bundles = list((case_root / "state/ai-sandbox/bundles").glob("*.bundle"))
        assert len(bundles) == 1 and not bundles[0].name.endswith(".failed.bundle")
        recovered = Path(case["recovered"]).read_text()
        for ref in output("for-each-ref", "--format=%(refname)", cwd=case["main"]).splitlines():
            git("update-ref", "-d", ref, cwd=case["main"])
        for checkout in {case["main"], case["worktree"]}:
            git("symbolic-ref", "HEAD", "refs/heads/pruned", cwd=checkout)
        git("reflog", "expire", "--expire=now", "--all", cwd=case["main"])
        git("gc", "--prune=now", cwd=case["main"])
        git("bundle", "verify", str(bundles[0]), cwd=case["main"])
        empty = case_root / "empty"
        git("init", "--quiet", "--bare", str(empty), cwd=case_root)
        git("bundle", "verify", str(bundles[0]), cwd=empty)
        # Run the printed command verbatim in argv form, including its HEAD
        # refspec. Merely fetching refs/* would silently lose detached work.
        instruction = next(line.split("git fetch ", 1)[1] for line in result.stderr.splitlines() if "git fetch " in line)
        command = ["git", "fetch", *shlex.split(instruction)]
        fetched = subprocess.run(command, cwd=case["main"], text=True, capture_output=True)
        assert fetched.returncode == 0, (command, fetched.stderr)
        assert recovered in output("for-each-ref", "--format=%(objectname)", "refs/recovered/", cwd=case["main"]).splitlines()
    print("PASS: branch/detached/unborn recovery survives host ref deletion and gc, verifies in empty repo, and printed fetch command restores guest HEAD despite origin advancing")

    for mode in ["export-failure", "invalid-bundle", "malformed-ref", "missing-export", "runner-failure", "truncated-pack"]:
        case_root, case = setup(mode=mode)
        result = invoke(case_root, case, expected=125)
        assert "failed" in result.stderr
        if mode in ("invalid-bundle", "malformed-ref", "truncated-pack"):
            failed = list((case_root / "state/ai-sandbox/bundles").glob("*.failed.bundle"))
            expected_payload = b"truncated bundle\n" if mode == "invalid-bundle" else Path(case["corrupted"]).read_bytes()
            assert len(failed) == 1 and failed[0].read_bytes() == expected_payload
    print("PASS: corrupt header, malformed ref, truncated pack, missing graceful export and failed VM return infrastructure failure and clean session pins")

    for refusal in ["alternates", "http-alternates", "partial-config", "promisor-config", "promisor-pack", "shallow"]:
        case_root, case = setup()
        main = Path(case["main"])
        common = main / ".git"
        if refusal in ("alternates", "http-alternates"):
            (common / "objects/info" / refusal).write_text(str(root) + "\n")
        elif refusal == "partial-config":
            git("config", "extensions.partialClone", "origin", cwd=main)
        elif refusal == "promisor-config":
            git("config", "remote.origin.promisor", "true", cwd=main)
        elif refusal == "promisor-pack":
            (common / "objects/pack/fixture.promisor").touch()
        else:
            (common / "shallow").write_text(case["head"] + "\n")
        result = subprocess.run([str(host)], cwd=main, env=env, text=True, capture_output=True)
        assert result.returncode == 2 and "unsupported" in result.stderr, (refusal, result.returncode, result.stderr)
    outside = root / "outside"
    outside.mkdir()
    result = subprocess.run([str(host)], cwd=outside, env=env, text=True, capture_output=True)
    assert result.returncode == 2 and "Git repository" in result.stderr
    print("PASS: shallow, partial, promisor, alternate-object and non-repository launches are refused")

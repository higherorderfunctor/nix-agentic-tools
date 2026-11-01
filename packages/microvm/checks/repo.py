"""Exercise the launcher's repository share and the guest clone without KVM.

The stub runner stands in for QEMU: it resolves the runtime directory's `repo`
link, which QEMU exports read-only at /mnt/repo, and runs the production guest
command against it.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

launcher, runner, guest, python = sys.argv[1:]


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    env = dict(
        os.environ,
        GIT_AUTHOR_DATE="2000-01-01T00:00:00Z",
        GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_AUTHOR_NAME="t",
        GIT_COMMITTER_DATE="2000-01-01T00:00:00Z",
        GIT_COMMITTER_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t",
        GIT_CONFIG_NOSYSTEM="1",
        HOME=str(root),
        TMPDIR=str(root),
    )
    os.environ.update(env)
    main = root / "main"
    main.mkdir()
    git("init", "--quiet", "--initial-branch=main", cwd=main)
    (main / "file").write_text("one\n")
    git("add", "file", cwd=main)
    git("commit", "--quiet", "-m", "first", cwd=main)
    worktree = root / "worktree"
    git("worktree", "add", "--quiet", "-b", "topic", str(worktree), cwd=main)
    (worktree / "sub").mkdir()
    (worktree / "sub" / "file").write_text("two\n")
    git("add", "sub/file", cwd=worktree)
    git("commit", "--quiet", "-m", "second", cwd=worktree)
    head = git("rev-parse", "HEAD", cwd=worktree)
    assert head != git("rev-parse", "HEAD", cwd=main)
    (worktree / "uncommitted").write_text("host only\n")
    (worktree / "file").write_text("modified on host\n")
    # The guest must not need write access to the shared directory.
    subprocess.run(["chmod", "-R", "a-w", str(main / ".git")], check=True)

    clone = root / "clone"
    guest_script = root / "guest"
    guest_script.write_text(
        Path(guest)
        .read_text()
        .replace("/run/sandbox/", '"$SANDBOX_RUN"/')
        .replace("/mnt/repo", '"$SANDBOX_REPO"')
        .replace("/home/sandbox/repo", str(clone))
    )
    guest_script.chmod(0o755)
    stub = root / "runner"
    stub.write_text(
        f"#!{python}\n"
        "import os, pathlib, subprocess\n"
        "cwd = pathlib.Path.cwd()\n"
        "assert (cwd / 'repo').is_symlink()\n"
        "os.environ['SANDBOX_REPO'] = str((cwd / 'repo').resolve())\n"
        "os.environ['SANDBOX_RUN'] = str(cwd)\n"
        f"code = subprocess.run([{str(guest_script)!r}]).returncode\n"
        "(cwd / 'status').write_text(f'exited:{code}\\n')\n"
    )
    stub.chmod(0o755)
    host = root / "host"
    source = Path(launcher).read_text()
    assert source.count(runner) == 1
    host.write_text(source.replace(runner, str(stub)).replace("/dev/kvm", str(root)))
    host.chmod(0o755)

    result = subprocess.run([str(host), "--", "uncommitted"], cwd=worktree / "sub", text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    report = dict(line.split("=", 1) for line in result.stdout.splitlines() if line.startswith("REPO_"))
    assert report["REPO_PWD"] == str(clone), report
    assert report["REPO_SRC"] == str((main / ".git").resolve()), report
    assert report["REPO_HEAD"] == head, report
    assert report["REPO_LOG"] == f"{head} second", report
    assert report["REPO_STATUS_LINES"] == "0", report
    assert report["REPO_HOST_ONLY"] == "absent", report
    assert report["REPO_WRITE"] == "denied", report
    assert (clone / "file").read_text() == "one\n"
    assert not any(p.name.startswith("sandbox-write") for p in (main / ".git").rglob("*"))
    print("PASS: linked worktree HEAD cloned shared from the read-only common directory; uncommitted changes absent")

    outside = root / "outside"
    outside.mkdir()
    result = subprocess.run([str(host)], cwd=outside, text=True, capture_output=True)
    assert result.returncode == 2, (result.returncode, result.stderr)
    assert "run inside a Git checkout" in result.stderr
    print("PASS: launch outside a checkout is rejected")

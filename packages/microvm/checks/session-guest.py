"""The real guest checks identity precedence and the two transmitted packs."""

import os
import re
import socket
import subprocess
import sys
from pathlib import Path


def git(*args, expected=0, **kwargs):
    result = subprocess.run(["git", *args], text=True, capture_output=True, **kwargs)
    assert result.returncode == expected, (args, result.stdout, result.stderr)
    return result.stdout.strip()


if sys.argv[1] == "outside":
    assert Path.cwd() == Path("/home/sandbox")
    assert not Path("repo/.git").exists()
    assert list(Path("/sys/class/net").iterdir()) == [Path("/sys/class/net/lo")]
    print("SESSION_OUTSIDE_OK", flush=True)
elif sys.argv[1] == "no-remote":
    assert git("remote", "get-url", "origin") == "/mnt/seed"
    assert list(Path("/sys/class/net").iterdir()) == [Path("/sys/class/net/lo")]
    assert git("config", "--get", "user.email", expected=1) == ""
    result = subprocess.run(["git", "push", "origin", "HEAD"], text=True, capture_output=True)
    assert result.returncode != 0, result.stdout
    print("SESSION_NO_REMOTE_OK", flush=True)
else:
    assert git("config", "user.name") == "Guest Session Bot"
    assert git("config", "user.email") == "guest-session@example.invalid"
    assert git("config", "--bool", "commit.gpgSign") == "false"
    assert git("config", "--bool", "tag.gpgSign") == "false"
    origin = git("remote", "get-url", "origin")
    assert re.fullmatch(r"git://10\.0\.2\.100:9418/sessions/[0-9a-f]{32}\.git", origin), origin
    assert git("remote", "get-url", "--push", "origin") == origin
    assert git("config", "--bool", "remote.origin.prune") == "false"
    assert git("config", "branch.main.remote") == "origin"
    assert git("config", "branch.main.merge") == "refs/heads/main"
    seed = git("rev-parse", "HEAD")
    for index in (1, 2):
        Path(f"guest-{index}").write_text(f"guest session change {index}\n")
        git("add", f"guest-{index}")
        git("commit", "--quiet", "-m", f"guest-{index}")
        result = subprocess.run(
            ["git", "push", "--progress", "origin", "HEAD"],
            env=os.environ | {"GIT_TRACE_PACKET": "1"},
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        written = re.findall(r"Writing objects: 100% \((\d+)/(\d+)\)", result.stderr)
        assert written and written[-1] == ("3", "3"), result.stderr
        if index == 1:
            assert f"{seed} .have" in result.stderr, result.stderr
        print(f"SESSION_PUSH_{index}_OK objects=3 head={git('rev-parse', 'HEAD')}", flush=True)
    with socket.create_connection(("10.0.2.100", 9418), timeout=10) as connection:
        unknown = "git-upload-pack /sessions/" + "0" * 32 + ".git\0host=10.0.2.100\0"
        connection.sendall(f"{len(unknown) + 4:04x}".encode() + unknown.encode())
        assert b"ERR" in connection.recv(4096)
    print("SESSION_GUEST_OK", flush=True)

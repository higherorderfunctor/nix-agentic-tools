# cspell:ignore askpass ASKPASS guestfwd SSHSIG urandom WAITALL
"""Drive a real ssh-agent through the signing door command, without a VM.

argv: the door command and its arguments before the agent socket, which this
check appends as mkSandbox does. socat serves each client connection on
stdin/stdout, as QEMU's guestfwd runs the door. A plain
`socat STDIO UNIX-CONNECT:<socket>` door fails at the login-style sign request.
"""

import base64
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

door = sys.argv[1:]


def run(*args, expected=0, **kwargs):
    result = subprocess.run(args, capture_output=True, **kwargs)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


def wait_socket(path, process):
    for _ in range(200):
        assert process.poll() is None, (path, process.returncode)
        if path.is_socket():
            return
        time.sleep(0.05)
    raise AssertionError(f"no socket at {path}")


def ssh_string(data):
    return struct.pack(">I", len(data)) + data


def agent_request(path, body):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(str(path))
        client.sendall(ssh_string(body))
        header = client.recv(4, socket.MSG_WAITALL)
        (length,) = struct.unpack(">I", header)
        return client.recv(length, socket.MSG_WAITALL)


with tempfile.TemporaryDirectory(prefix="agent-filter-") as temporary:
    root = Path(temporary)
    processes = []
    try:
        for name in ["signing", "other"]:
            run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", str(root / name))
        signing_public = (root / "signing.pub").read_text().split()[:2]
        agent_socket = root / "agent.sock"
        door_socket = root / "door.sock"
        env = {"PATH": os.environ["PATH"], "SSH_AUTH_SOCK": str(door_socket)}
        agent_env = env | {"SSH_AUTH_SOCK": str(agent_socket)}
        agent = subprocess.Popen(["ssh-agent", "-D", "-a", str(agent_socket)], stdout=subprocess.DEVNULL)
        processes.append(agent)
        wait_socket(agent_socket, agent)
        run("ssh-add", "-q", str(root / "signing"), env=agent_env)
        door_log = open(root / "door.log", "w")
        exec_door = " ".join(door + [str(agent_socket)])
        bridge = subprocess.Popen(["socat", f"UNIX-LISTEN:{door_socket},fork", f"EXEC:{exec_door}"], stderr=door_log)
        processes.append(bridge)
        wait_socket(door_socket, bridge)

        def agent_keys():
            return [line.split()[:2] for line in run("ssh-add", "-L", env=agent_env, text=True).splitlines()]

        assert [line.split()[:2] for line in run("ssh-add", "-L", env=env, text=True).splitlines()] == [signing_public]
        print("PASS: identities list through the door", flush=True)

        message = root / "message"
        message.write_text("tree 0000000000000000000000000000000000000000\n")
        signature = run("ssh-keygen", "-Y", "sign", "-n", "git", "-f", str(root / "signing.pub"), "-U", input=message.read_bytes(), env=env)
        (root / "allowed").write_text("fixture@example.invalid " + " ".join(signing_public) + "\n")
        (root / "message.sig").write_bytes(signature)
        run("ssh-keygen", "-Y", "verify", "-f", str(root / "allowed"), "-I", "fixture@example.invalid", "-n", "git", "-s", str(root / "message.sig"), input=message.read_bytes(), env=env)
        print("PASS: SSHSIG signature through the door verifies", flush=True)

        # RFC 4252 user-auth data: string session id, byte 50, user, service,
        # "publickey", true, algorithm and key. The agent itself signs it.
        key_blob = base64.b64decode(signing_public[1])
        login = (
            ssh_string(os.urandom(32)) + bytes([50]) + ssh_string(b"git") + ssh_string(b"ssh-connection")
            + ssh_string(b"publickey") + bytes([1]) + ssh_string(b"ssh-ed25519") + ssh_string(key_blob)
        )
        sign_login = bytes([13]) + ssh_string(key_blob) + ssh_string(login) + struct.pack(">I", 0)
        assert agent_request(agent_socket, sign_login)[0] == 14, "positive control: the agent signs a login challenge"
        assert agent_request(door_socket, sign_login) == bytes([5]), "login challenge signed through the door"
        print("PASS: login-style sign request refused", flush=True)

        (root / "askpass").write_text("#!/bin/sh\necho fixture-lock\n")
        (root / "askpass").chmod(0o700)
        askpass = env | {"DISPLAY": "none", "SSH_ASKPASS": str(root / "askpass"), "SSH_ASKPASS_REQUIRE": "force"}
        for args in [["-D"], ["-d", str(root / "signing.pub")], [str(root / "other")], ["-x"]]:
            refused = subprocess.run(["ssh-add", *args], env=askpass, capture_output=True, stdin=subprocess.DEVNULL)
            assert refused.returncode != 0, (args, refused)
            # A locked agent lists no identities, so this also proves -x did nothing.
            assert agent_keys() == [signing_public], (args, agent_keys())
        print("PASS: ssh-add -D, -d, add and -x refused; agent keys unchanged", flush=True)

        # Malformed framing closes the connection instead of reaching the agent.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(door_socket))
            client.sendall(struct.pack(">I", 1024 * 1024))
            assert client.recv(1) == b"", "oversized length kept the connection open"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(door_socket))
            client.sendall(ssh_string(bytes([13]) + ssh_string(key_blob) + struct.pack(">I", 99)))
            assert client.recv(1) == b"", "truncated sign request kept the connection open"
        assert agent_keys() == [signing_public]
        door_log.close()
        log = (root / "door.log").read_text()
        for refusal in ["not an SSHSIG envelope", "type 17", "type 18", "type 19", "type 22", "outside 1..", "truncated string"]:
            assert refusal in log, (refusal, log)
        print("PASS: malformed messages close the connection; refusals reach only the door log", flush=True)
    finally:
        for process in processes:
            process.terminate()
            process.wait(timeout=10)

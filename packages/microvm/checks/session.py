# cspell:ignore gpgsig pkey
"""Run the module launcher against a session relay and a real local SSH upstream."""

import fcntl
import json
import os
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

codex, claude, relay, sshd, git_shell, bash, state_name, signer = sys.argv[1:]
state = Path(state_name)


def run(*args, expected=0, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip()


def git(*args, **kwargs):
    return run("git", *args, **kwargs)


def wait_port(port, process):
    for _ in range(200):
        assert process.poll() is None, ("server exited", process.returncode)
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError(f"server did not listen on {port}")


with open(state_name + ".lock", "w") as lock, tempfile.TemporaryDirectory(prefix="sandbox-session-") as temporary:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state.mkdir(mode=0o700)
    root = Path(temporary)
    processes = []
    logs = []
    env = os.environ | {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "SSH_AUTH_SOCK": str(root / "inherited-agent-must-not-be-used"),
        "XDG_RUNTIME_DIR": str(root / "runtime"),
        "XDG_STATE_HOME": str(root / "recovery"),
    }
    Path(env["XDG_RUNTIME_DIR"]).mkdir()
    (state / "signer-runtime").mkdir()
    signer_socket = state / "signer-runtime/ai-service-sandbox-signer-codex-work/agent.sock"
    agent_env = env | {"SSH_AUTH_SOCK": str(signer_socket)}
    try:
        # A public fixed test seed gives the evaluated module a stable host pin;
        # its private key is generated only inside this check's runtime directory.
        subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-out", str(state / "host-key")],
            input=bytes.fromhex("302e020100300506032b657004220420") + bytes(range(32)),
            check=True,
            capture_output=True,
        )
        (state / "host-key").chmod(0o600)
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(state / "client-key"))
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(state / "signing-key"))
        (state / "authorized_keys").write_text((state / "client-key.pub").read_text())
        host_public = run("ssh-keygen", "-y", "-f", str(state / "host-key"))
        upstream = root / "upstream.git"
        work = root / "work"
        git("init", "--bare", "--quiet", "--initial-branch=main", str(upstream), env=env)
        git("init", "--quiet", "--initial-branch=main", str(work), env=env)
        for index in range(64):
            (work / f"seed-{index}").write_text(f"host seed object {index}\n")
        git("-C", str(work), "add", ".", env=env)
        git("-C", str(work), "-c", "user.name=Host Fixture", "-c", "user.email=host@example.invalid", "commit", "--quiet", "-m", "seed", env=env)
        git("-C", str(work), "push", "--quiet", str(upstream), "HEAD:main", env=env)
        git("-C", str(upstream), "config", "receive.unpackLimit", "1", env=env)
        # A host branch never pushed upstream, which the guest must neither read nor publish.
        git("-C", str(work), "checkout", "--quiet", "-b", "host-only", env=env)
        (work / "host-token").write_text("host-only token\n")
        git("-C", str(work), "add", "host-token", env=env)
        git("-C", str(work), "-c", "user.name=Host Fixture", "-c", "user.email=host@example.invalid", "commit", "--quiet", "-m", "host-only", env=env)
        host_only = git("-C", str(work), "rev-parse", "HEAD", env=env)
        git("-C", str(work), "checkout", "--quiet", "main", env=env)
        seeded = git("-C", str(work), "rev-parse", "HEAD", env=env)
        recorder = upstream / "hooks/pre-receive"
        recorder.write_text(
            f"#!{bash}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
            "total=0 fresh=0\n"
            "while read -r object; do\n"
            "  total=$((total + 1))\n"
            "  if ! env -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES "
            "git cat-file -e \"$object\" 2>/dev/null; then fresh=$((fresh + 1)); fi\n"
            "done < <(git verify-pack -v \"$GIT_QUARANTINE_PATH\"/pack/*.idx | "
            "awk '$2 ~ /^(blob|commit|tag|tree)$/ { print $1 }')\n"
            "printf '%s %s\\n' \"$total\" \"$fresh\" >> \"$GIT_DIR/received-counts\"\n"
            "cat >/dev/null\n"
        )
        recorder.chmod(0o755)
        ssh_config = root / "sshd.conf"
        ssh_config.write_text(
            "ListenAddress 127.0.0.1\nPort 29422\n"
            f"HostKey {state}/host-key\nAuthorizedKeysFile {state}/authorized_keys\n"
            f"PidFile {root}/sshd.pid\nAllowUsers {pwd.getpwuid(os.getuid()).pw_name}\n"
            "AuthenticationMethods publickey\nPasswordAuthentication no\n"
            "KbdInteractiveAuthentication no\nStrictModes no\nUsePAM no\n"
            f"SetEnv PATH={os.environ['PATH']}\n"
            f"ForceCommand {git_shell} -c \"$SSH_ORIGINAL_COMMAND\"\n"
        )
        config = {
            "credentials": {name: {"forges": ["127.0.0.1"], "sshKeyFile": str(state / "client-key")} for name in ["codex-unsigned", "codex-work"]},
            "forges": {"127.0.0.1": {"hostKeys": f"[127.0.0.1]:29422 {host_public}"}},
            "listen": "127.0.0.1",
            "port": 29418,
            "repositories": {},
            "sessions": True,
        }
        config_path = root / "relay.json"
        config_path.write_text(json.dumps(config))
        relay_env = env | {"GIT_RELAY_CONFIG": str(config_path)}
        for name, command, cwd, server_env, port in [
            ("sshd", [sshd, "-D", "-e", "-f", str(ssh_config)], root, env, 29422),
            ("relay", [relay], state, relay_env, 29418),
        ]:
            log = open(root / f"{name}.log", "w+")
            logs.append(log)
            process = subprocess.Popen(command, cwd=cwd, env=server_env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(process)
            wait_port(port, process)

        # This runtime has no assignment for codex-only, so it must refuse
        # before a VM or a session can exist.
        upstream_url = f"ssh://{pwd.getpwuid(os.getuid()).pw_name}@codex-only:29422{upstream}"
        git("-C", str(work), "remote", "add", "origin", upstream_url, env=env)
        refused = subprocess.run([claude, "--", "matched"], cwd=work, env=env, text=True, capture_output=True)
        assert refused.returncode != 0 and "unmatched remote token: codex-only" in refused.stderr, refused
        assert "VM runner" not in refused.stderr
        assert not list((state / "repositories/sessions").glob("*.git"))
        print("PASS: wrong runtime assignment refused before boot or session publication", flush=True)

        def refuse_signer():
            refused = subprocess.run([codex, "--", "signed"], cwd=work, env=env, text=True, capture_output=True)
            assert refused.returncode != 0 and "sandbox-signer-codex-work" in refused.stderr, refused
            assert "Booting" not in refused.stdout and "VM runner" not in refused.stderr, refused
            assert not list((state / "repositories/sessions").glob("*.git"))
            return refused

        refuse_signer()
        signer_log = open(root / "signer.log", "w+")
        logs.append(signer_log)
        signer_process = subprocess.Popen([signer], env=env, stdout=signer_log, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(signer_process)
        for _ in range(200):
            assert signer_process.poll() is None, "signer exited before loading its key"
            probe = subprocess.run(["ssh-add", "-L"], env=agent_env, text=True, capture_output=True)
            if probe.returncode == 0:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("signer did not become ready")
        assert probe.stdout.strip() == (state / "signing-key.pub").read_text().strip()
        # The signer removes the delivered private key once the agent holds it.
        delivered = signer_socket.parent / "SIGNING_KEY"
        for _ in range(200):
            if not delivered.exists():
                break
            time.sleep(0.05)
        else:
            raise AssertionError("signer kept its private key file")
        published = (signer_socket.parent / "agent.sock.pub").read_text().split()[:2]
        assert published == (state / "signing-key.pub").read_text().split()[:2], published
        assert signer_socket.parent.stat().st_mode & 0o777 == 0o700
        # Emptying, adding another key or swapping keys must not silently change the identity.
        run("ssh-add", str(state / "client-key"), env=agent_env)
        refuse_signer()
        run("ssh-add", "-D", env=agent_env)
        refuse_signer()
        run("ssh-add", str(state / "client-key"), env=agent_env)
        swapped = refuse_signer()
        assert "holds a key other than its configured signing key" in swapped.stderr, swapped
        run("ssh-add", "-D", env=agent_env)
        run("ssh-add", str(state / "signing-key"), env=agent_env)
        print("PASS: missing, empty, multi-key and swapped signer refuse before boot or session publication; signer removes its private key file", flush=True)

        guest_log = open(root / "guest.log", "w+")
        logs.append(guest_log)
        guest = subprocess.Popen([codex, "--", "signed"], cwd=work, env=env, stdout=guest_log, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(guest)
        sessions = state / "repositories/sessions"
        for _ in range(600):
            live = list(sessions.glob("*.git"))
            if live:
                break
            assert guest.poll() is None, "launcher exited before opening session"
            time.sleep(0.05)
        assert len(live) == 1, live
        session = live[0]
        token = session.stem
        # The session borrows the launcher's seed copy, never the host store.
        alternates = Path((session / "objects/info/alternates").read_text().strip())
        assert alternates.name == "seed-objects", alternates
        for _ in range(600):
            if alternates.exists():
                break
            time.sleep(0.05)
        assert alternates.resolve().parent.name == "seed", alternates.resolve()
        git("--git-dir", str(session), "cat-file", "-e", seeded, env=env)
        run("git", "--git-dir", str(session), "cat-file", "-e", host_only, expected=1, env=env)
        with open(state / "locks" / token) as session_lock:
            try:
                fcntl.flock(session_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("launcher published session without holding its lock")
        run(relay, "session", "gc", cwd=state, env=relay_env)
        assert session.is_dir()
        print("PASS: launcher holds session lock before publication; concurrent GC retains it; the session reaches seeded history but not a host-only branch", flush=True)
        assert guest.wait(timeout=180) == 0
        guest_log.seek(0)
        output = guest_log.read()
        for marker in ["SESSION_PUSH_1_OK objects=3", "SESSION_PUSH_2_OK objects=3", "SESSION_GUEST_OK", "SESSION_SIGNED_OK"]:
            assert marker in output, output
        assert not session.exists() and not (state / "locks" / token).exists()
        assert not list((state / "repositories/staging").glob("*.git"))
        assert git("-C", str(upstream), "log", "-2", "--format=%an <%ae>", env=env).splitlines() == [
            "Guest Session Bot <guest-session@example.invalid>",
            "Guest Session Bot <guest-session@example.invalid>",
        ]
        assert git("-C", str(upstream), "log", "-2", "--format=%s", env=env).splitlines() == ["guest-2", "guest-1"]
        received = [tuple(map(int, line.split())) for line in (upstream / "received-counts").read_text().splitlines()]
        # index-pack may append one already-present delta base to a thin pack.
        assert len(received) == 2 and all(3 <= total <= 4 and fresh == 3 for total, fresh in received), received
        print("PASS: two guest pushes reached actual SSH upstream as guest author, each guest pack sends exactly three new objects (verified in upstream quarantine); session and lock removed on exit", flush=True)

        allowed_signers = root / "allowed-signers"
        allowed_signers.write_text("guest-session@example.invalid " + (state / "signing-key.pub").read_text())
        for revision in ["HEAD", "HEAD~1"]:
            assert "gpgsig -----BEGIN SSH SIGNATURE-----" in git("-C", str(upstream), "cat-file", "commit", revision, env=env)
            git("-C", str(upstream), "-c", f"gpg.ssh.allowedSignersFile={allowed_signers}", "verify-commit", revision, env=env)
        print("PASS: guest verifies both signed commits; pushed upstream signatures verify against generated allowed-signers", flush=True)
        os.killpg(signer_process.pid, signal.SIGTERM)
        signer_process.wait(timeout=10)
        refuse_signer()
        print("PASS: stopped signer refuses before boot or session publication", flush=True)

        # The same runtime also selects an unsigned identity with no signing door.
        git("-C", str(work), "remote", "set-url", "origin", upstream_url.replace("codex-only", "codex-unsigned"), env=env)
        git("-C", str(work), "fetch", str(upstream), "main", env=env)
        git("-C", str(work), "reset", "--hard", "FETCH_HEAD", env=env)
        unsigned = run(codex, "--", "unsigned", cwd=work, env=env)
        assert "SESSION_UNSIGNED_OK" in unsigned, unsigned
        assert "gpgsig " not in git("-C", str(upstream), "cat-file", "commit", "HEAD", env=env)
        print("PASS: unsigned identity has no guest signing socket and pushes an unsigned commit with signer stopped", flush=True)

        git("-C", str(work), "remote", "remove", "origin", env=env)
        no_remote = run(codex, "--", "no-remote", cwd=work, env=env)
        assert "SESSION_NO_REMOTE_OK" in no_remote, no_remote
        assert not list(sessions.glob("*.git"))
        outside = root / "outside"
        outside.mkdir()
        no_repo = run(codex, "--", "outside", cwd=outside, env=env)
        assert "SESSION_OUTSIDE_OK" in no_repo, no_repo
        assert not list(sessions.glob("*.git"))
        print("PASS: no push remote keeps seeded repo with no relay door; non-repo runs plain guest with no door", flush=True)
    except BaseException:
        for log in logs:
            log.flush()
            log.seek(0)
            print(f"--- {log.name} ---\n{log.read()}", file=sys.stderr)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        for log in logs:
            log.close()
        shutil.rmtree(state)

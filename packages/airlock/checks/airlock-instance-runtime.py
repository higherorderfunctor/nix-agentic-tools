"""Start each backend's generated launcher: health at the configured port, a
private runtime config, a published certificate without the key, and reusable
client trust without a supervising process.

CI runs service/trust checks and missing-key refusals before bubblewrap. The
separate hand-run live check requires all real jailed probes to succeed; CI's
build sandbox cannot execute them. There is no fallback from live to CI mode.
"""

import argparse
import contextlib
import errno
import hashlib
import http.client
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


@contextlib.contextmanager
def running(launcher, environment, output):
    child = subprocess.Popen([launcher], env=environment, stdout=output, stderr=output)
    try:
        yield child
    except BaseException:
        output.seek(0)
        sys.stderr.write(output.read())
        raise
    finally:
        child.terminate()
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise


def healthy(config):
    host, port = config["listen"].rsplit(":", 1)
    assert int(port) != 8318, "a default port would not prove the config was read"
    connection = http.client.HTTPConnection(host, int(port), timeout=0.5)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        assert response.status == 200, response.status
        assert response.read() == b"ok\n"
        return True
    except OSError:
        return False
    finally:
        connection.close()


def private(path, mode):
    assert not path.is_symlink(), path
    metadata = path.stat()
    assert stat.S_IMODE(metadata.st_mode) == mode, path
    assert metadata.st_uid == os.getuid(), path


def launch_client(case, environment, inherited=None):
    """Run Claude's launcher; return its exit status, extra-CA file and stderr."""
    environment = dict(environment)
    environment.pop("NODE_EXTRA_CA_CERTS", None)
    if inherited is not None:
        environment["NODE_EXTRA_CA_CERTS"] = str(inherited)
    result = subprocess.run([case["client"]], env=environment, capture_output=True, timeout=10)
    extra = json.loads(result.stdout) if result.returncode == 0 else None
    return result.returncode, extra, result.stderr.decode()


def client_trust(case, environment, runtime):
    """An intercepting instance's CA reaches Claude, after any inherited CA."""
    bundle_directory = runtime.parent / ("ai-service-airlock-trust" if environment.get("XDG_RUNTIME_DIR")
                                       else f"ai-service-{os.getuid()}-airlock-trust")
    inherited = runtime.parent / "inherited.pem"
    inherited.write_bytes(b"inherited certificate fixture\n")
    status, extra, error = launch_client(case, environment)
    assert status == 0, error
    if not case["intercepting"]:
        assert extra is None, "an opaque selection set an extra CA"
        assert launch_client(case, environment, inherited)[1]["path"] == str(inherited)
        return
    override = case | {"client": case["clientOverride"]}
    ca = runtime.with_name(runtime.name + ".trust") / "ca.pem"
    assert extra["content"] == ca.read_text()
    native = launch_client(override, environment, inherited)[1]
    assert native["content"] == Path(case["nativeCa"]).read_text() + "\n" + ca.read_text(), "native CA replaced Airlock trust"
    status, bundle, error = launch_client(case, environment, inherited)
    assert status == 0, error
    assert bundle["content"] == inherited.read_text() + "\n" + ca.read_text()
    relaunched = launch_client(case, environment, inherited)[1]
    assert relaunched["path"] == bundle["path"], "identical inputs did not reuse their bundle"
    assert extra["path"] == str(ca), "a single CA should use the published file"
    for result, source in ((native, Path(case["nativeCa"])), (bundle, inherited), (relaunched, inherited)):
        path = Path(result["path"])
        assert path.parent == bundle_directory, path
        expected = source.read_bytes() + b"\n" + ca.read_bytes()
        assert path.name == hashlib.sha256(expected).hexdigest() + ".pem", path
        assert result["mode"] == 0o600 and result["uid"] == os.getuid(), result
        private(path.parent, 0o700)
        assert path.read_text() == result["content"], "an exited client lost its bundle"
    inherited.write_bytes(b"changed inherited certificate fixture\n")
    changed = launch_client(case, environment, inherited)[1]
    assert changed["path"] != bundle["path"], "changed inputs reused stale trust"
    assert changed["content"] == inherited.read_text() + "\n" + ca.read_text()
    status, _, _ = launch_client(case, environment | {"AIRLOCK_TEST_EXIT": "37"}, inherited)
    assert status == 37, "the launcher lost the command's exit status"
    with tempfile.TemporaryFile() as descriptor:
        descriptor.write(b"airlock inherited fd\n")
        descriptor.seek(0)
        result = subprocess.run(
            [case["client"]], pass_fds=(descriptor.fileno(),), capture_output=True, timeout=10,
            env=environment | {"AIRLOCK_TEST_FD": str(descriptor.fileno()), "NODE_EXTRA_CA_CERTS": str(inherited)},
        )
        assert result.returncode == 0, result.stderr.decode()
    status, _, error = launch_client(case, environment, inherited.with_name("missing.pem"))
    assert status != 0, "a missing inherited CA was dropped"
    assert not list(bundle_directory.glob(".bundle.*")), "a failed launch left a temporary bundle"


def concurrent_clients(case, environment, runtime):
    """Shared composed bundles survive clients; group signals keep signal status."""
    with contextlib.ExitStack() as stack:
        paths = []
        children = []
        pipes = []
        for index in range(4):
            # Each helper blocks reading its own FIFO after creating its temporary
            # bundle. Release all writers only after all four helpers reach cat.
            pipe = runtime.parent / f"concurrent-{index}.pem"
            os.mkfifo(pipe)
            stack.callback(pipe.unlink)
            child = subprocess.Popen(
                [case["client"]],
                env=environment | {"AIRLOCK_TEST_WAIT": "1", "NODE_EXTRA_CA_CERTS": str(pipe)},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
            )
            stack.callback(lambda process=child: process.poll() is None and os.killpg(process.pid, signal.SIGKILL))
            children.append(child)
            pipes.append(pipe)
        writers = []
        deadline = time.monotonic() + 10
        for pipe in pipes:
            while True:
                try:
                    writer = os.open(pipe, os.O_WRONLY | os.O_NONBLOCK)
                    break
                except OSError as error:
                    assert error.errno == errno.ENXIO, error
                    assert time.monotonic() < deadline, "trust helpers did not reach the bundle barrier"
                    time.sleep(0.01)
            writers.append(stack.enter_context(os.fdopen(writer, "wb")))
        # All helpers have created a temporary bundle and none can publish yet.
        temporaries = list(runtime.parent.glob("ai-service-*airlock-trust/.bundle.*"))
        assert len(temporaries) == 4, temporaries
        for writer in writers:
            writer.write(b"concurrent inherited certificate fixture\n")
            writer.close()
        for child in children:
            result = json.loads(child.stdout.readline())
            assert result["pid"] == child.pid, "the launcher left a supervising process between it and Claude"
            path = Path(result["path"])
            private(path, 0o600)
            private(path.parent, 0o700)
            assert result["content"] == "concurrent inherited certificate fixture\n\n" + (runtime / "ca/ca.pem").read_text()
            paths.append(path)
        assert len(set(paths)) == 1, "concurrent launches did not reuse identical trust"
        for child, number in zip(children, (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM)):
            os.killpg(child.pid, number)
            _, error = child.communicate(timeout=10)
            assert child.returncode == -number, (child.returncode, error)
            assert paths[0].exists(), "a client's exit removed shared trust"


def missing_ca_refused(case):
    """Before the service has made its CA, Claude's launcher refuses to start."""
    with tempfile.TemporaryDirectory(prefix="airlock-client-") as directory:
        status, _, error = launch_client(case, os.environ | {"XDG_RUNTIME_DIR": directory})
    if case["intercepting"]:
        assert status != 0 and "no CA at" in error and "start airlock-main" in error, error
    else:
        assert status == 0, error


def jailed_clients(case):
    return [case[name] for name in ("jailedNativeClient", "jailedProbe", "jailedClient")]


def missing_key_refused(case):
    """Even native-CA Claude and a client with no trust delivery fail closed."""
    for runtime_variable in ("XDG_RUNTIME_DIR", "TMPDIR"):
        with tempfile.TemporaryDirectory(prefix="airlock-missing-key-") as directory:
            environment = dict(os.environ)
            environment.pop("XDG_RUNTIME_DIR", None)
            environment[runtime_variable] = directory
            name = ("ai-service-airlock-main" if runtime_variable == "XDG_RUNTIME_DIR"
                    else f"ai-service-{os.getuid()}-airlock-main")
            key = Path(directory) / name / "ca" / "ca.key"
            for client in jailed_clients(case):
                result = subprocess.run([client], env=environment, capture_output=True, timeout=10)
                error = result.stderr.decode()
                assert result.returncode != 0, "jailed client launched without a CA key"
                assert f"airlock-main: cannot jail client: CA key missing or inaccessible at {key}" in error, error
                assert "same XDG_RUNTIME_DIR/TMPDIR" in error, error


def jail_clients(case, environment, runtime):
    """Use a real CA from the generated service and production jail permissions."""
    # The Codex-profile probe has no trust helper and must see an empty key
    # while the certificate remains readable. Removing the mask exposes it.
    assert (runtime / "ca" / "ca.key").stat().st_size > 0
    result = subprocess.run(
        [case["jailedProbe"], str(runtime)], env=environment, capture_output=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout.strip() == b"CA key hidden; certificate readable", result.stdout
    jailed = case | {"client": case["jailedClient"], "clientOverride": case["jailedNativeClient"]}
    client_trust(jailed, environment, runtime)
    # A different client runtime directory must refuse rather than skip the mask.
    missing_key_refused(case)
    print("AIRLOCK-JAIL: real CA key masked, certificate readable, trust helper ran inside jail", flush=True)


def start_twice(case, live, runtime_variable="XDG_RUNTIME_DIR"):
    """Return the CA certificate each start of one runtime directory used."""
    certificates = []
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        environment = dict(os.environ)
        environment.pop("XDG_RUNTIME_DIR", None)
        environment[runtime_variable] = directory
        if runtime_variable == "TMPDIR":
            # A shared sticky root may already contain another user's old fixed
            # trust name. The uid-qualified service naming must avoid that entry.
            Path(directory).chmod(0o1777)
            (Path(directory) / "airlock-trust").symlink_to("unrelated-user-trust")
        name = ("ai-service-airlock-main" if runtime_variable == "XDG_RUNTIME_DIR"
                else f"ai-service-{os.getuid()}-airlock-main")
        runtime = Path(directory) / name
        with (Path(directory) / "output").open("w+") as output:
            for _ in range(2):
                with running(case["launcher"], environment, output) as child:
                    deadline = time.monotonic() + 10
                    while not healthy(case["config"]):
                        assert child.poll() is None, "service exited before readiness"
                        assert time.monotonic() < deadline, "service readiness timed out"
                        time.sleep(0.02)
                    private(runtime, 0o700)
                    private(runtime / "config.json", 0o600)
                    rendered = json.loads((runtime / "config.json").read_text())
                    assert rendered == case["config"], rendered
                    ca = runtime / "ca"
                    if case["intercepting"]:
                        # Readiness comes after the CA is created or validated.
                        private(ca, 0o700)
                        private(ca / "ca.key", 0o600)
                        certificates.append((ca / "ca.pem").read_bytes())
                        published = runtime.with_name(runtime.name + ".trust")
                        private(published, 0o700)
                        private(published / "ca.pem", 0o600)
                        assert (published / "ca.pem").read_bytes() == certificates[-1]
                        assert sorted(path.name for path in published.iterdir()) == ["ca.pem"], "publication exposed private files"
                        # Client trust must work with the private service directory
                        # inaccessible. This fails when the helper still reads there.
                        runtime.chmod(0o000)
                        try:
                            client_trust(case, environment, runtime)
                        finally:
                            runtime.chmod(0o700)
                        # Path.glob suppresses PermissionError, so assert only
                        # after restoring directory access.
                        assert not list(runtime.glob("*trust*")), "a client wrote trust into the private service directory"
                        concurrent_clients(case, environment, runtime)
                    else:
                        assert not ca.exists(), "an opaque instance created a CA"
                        client_trust(case, environment, runtime)
                    if case["intercepting"] and live:
                        jail_clients(case, environment, runtime)
                assert child.returncode == 0, child.returncode
    return certificates


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("ci", "live"))
    parser.add_argument("cases", type=Path)
    args = parser.parse_args()
    live = args.mode == "live"
    print("AIRLOCK: mandatory real jail probes" if live else
          "AIRLOCK: CI service/trust checks; real jail requires airlock-instance-jail-live", flush=True)
    for case in json.loads(args.cases.read_text()):
        case["config"] = json.loads(case["config"])
        missing_ca_refused(case)
        if case["intercepting"]:
            missing_key_refused(case)
        certificates = start_twice(case, live)
        fallback = start_twice(case, live, "TMPDIR")
        if case["intercepting"]:
            first, restarted = certificates
            assert first.startswith(b"-----BEGIN CERTIFICATE-----")
            assert restarted == first, "a restart replaced the runtime CA"
            assert fallback[0] != first, "the TMPDIR fallback reused another runtime's CA"
            assert start_twice(case, live)[0] != first, "a new runtime directory reused a CA"
        print(f"ok: {case['backend']} intercepting={case['intercepting']}")

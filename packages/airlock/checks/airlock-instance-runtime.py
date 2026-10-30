"""Start each backend's generated launcher: health at the configured port, a
private runtime config, an interception CA in the instance's runtime directory,
and reusable client trust without a supervising process. devenv roots that
directory under its own runtime root, which here is the shared /tmp, so its
intercepting service must refuse to start and its clients must refuse that
directory, empty or holding a planted CA.

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
import shutil
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


def ca_directory(case, runtime):
    """Where the service's `airlock ca init --instance main` keeps the CA."""
    if case["home"] is not None:
        return Path(case["home"]) / "runtime" / "main"
    return Path(runtime) / "airlock" / "main"


def refused(directory):
    """How Airlock refuses `directory` when a directory on its canonical path
    is owned by another user or writable by group or others."""
    return f" cannot hold {os.path.realpath(directory)}: it "


def launch_client(case, environment, inherited=None):
    """Run Claude's launcher; return its exit status, extra-CA file and stderr."""
    environment = dict(environment)
    environment.pop("NODE_EXTRA_CA_CERTS", None)
    if inherited is not None:
        environment["NODE_EXTRA_CA_CERTS"] = str(inherited)
    result = subprocess.run([case["client"]], env=environment, capture_output=True, timeout=10)
    extra = json.loads(result.stdout) if result.returncode == 0 else None
    return result.returncode, extra, result.stderr.decode()


def client_trust(case, environment, directory, scratch):
    """An intercepting instance's CA reaches Claude, after any inherited CA."""
    inherited = scratch / "inherited.pem"
    inherited.write_bytes(b"inherited certificate fixture\n")
    status, extra, error = launch_client(case, environment)
    assert status == 0, error
    if not case["intercepting"]:
        assert extra is None, "an opaque selection set an extra CA"
        assert launch_client(case, environment, inherited)[1]["path"] == str(inherited)
        return
    override = case | {"client": case["clientOverride"]}
    ca = directory / "ca.pem"
    assert extra["content"] == ca.read_text()
    native = launch_client(override, environment, inherited)[1]
    assert native["content"] == Path(case["nativeCa"]).read_text() + "\n" + ca.read_text(), "native CA replaced Airlock trust"
    status, bundle, error = launch_client(case, environment, inherited)
    assert status == 0, error
    assert bundle["content"] == inherited.read_text() + "\n" + ca.read_text()
    relaunched = launch_client(case, environment, inherited)[1]
    assert relaunched["path"] == bundle["path"], "identical inputs did not reuse their bundle"
    assert extra["path"] == str(ca), "a single CA should use the instance's certificate"
    for result, source in ((native, Path(case["nativeCa"])), (bundle, inherited), (relaunched, inherited)):
        path = Path(result["path"])
        assert path.parent == directory, path
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
    assert not list(directory.glob(".bundle.*")), "a failed launch left a temporary bundle"
    # The client finds the CA where the service made it, with no fallback.
    unset = dict(environment)
    unset.pop("XDG_RUNTIME_DIR")
    status, _, error = launch_client(case, unset)
    assert status != 0 and "XDG_RUNTIME_DIR is unset or empty" in error, error


def concurrent_clients(case, environment, directory, scratch):
    """Shared composed bundles survive clients; group signals keep signal status."""
    with contextlib.ExitStack() as stack:
        paths = []
        children = []
        pipes = []
        for index in range(4):
            # Each helper blocks reading its own FIFO after creating its temporary
            # bundle. Release all writers only after all four helpers reach cat.
            pipe = scratch / f"concurrent-{index}.pem"
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
        temporaries = list(directory.glob(".bundle.*"))
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
            assert result["content"] == "concurrent inherited certificate fixture\n\n" + (directory / "ca.pem").read_text()
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
            ca = ca_directory(case, directory) / "ca.pem"
            # devenv's runtime root here is the shared /tmp, refused before it is read.
            if case["home"] is not None:
                assert status != 0 and refused(ca.parent) in error, error
            else:
                assert status != 0 and f"no CA at {ca}" in error and "start airlock-main" in error, error
        else:
            assert status == 0, error


def jailed_clients(case):
    return [case[name] for name in ("jailedNativeClient", "jailedProbe", "jailedClient")]


def missing_key_refused(case):
    """Even native-CA Claude and a client with no trust delivery fail closed."""
    with tempfile.TemporaryDirectory(prefix="airlock-missing-key-") as directory:
        environment = os.environ | {"XDG_RUNTIME_DIR": directory}
        key = ca_directory(case, directory) / "ca.key"
        for client in jailed_clients(case):
            result = subprocess.run([client], env=environment, capture_output=True, timeout=10)
            error = result.stderr.decode()
            assert result.returncode != 0, "jailed client launched without a CA key"
            # devenv's runtime root here is the shared /tmp, refused before it is read.
            if case["home"] is not None:
                assert refused(key.parent) in error, error
                continue
            assert f"airlock-main: cannot jail client: CA key missing or inaccessible at {key}" in error, error
            assert "start airlock-main before launching" in error, error


def jail_clients(case, environment, directory, scratch):
    """Use a real CA from the generated service and production jail permissions."""
    # The Codex-profile probe has no trust helper and must see an empty key
    # while the certificate remains readable. Removing the mask exposes it.
    assert (directory / "ca.key").stat().st_size > 0
    result = subprocess.run(
        [case["jailedProbe"], str(directory)], env=environment, capture_output=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout.strip() == b"CA key hidden; certificate readable", result.stdout
    jailed = case | {"client": case["jailedClient"], "clientOverride": case["jailedNativeClient"]}
    client_trust(jailed, environment, directory, scratch)
    # A different client runtime directory must refuse rather than skip the mask.
    missing_key_refused(case)
    print("AIRLOCK-JAIL: real CA key masked, certificate readable, trust helper ran inside jail", flush=True)


def refused_home(case):
    """devenv's runtime root here is the shared /tmp, so init must refuse it."""
    directory = ca_directory(case, None)
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as runtime:
        environment = os.environ | {"XDG_RUNTIME_DIR": runtime}
        result = subprocess.run([case["launcher"]], env=environment, capture_output=True, timeout=10)
        error = result.stderr.decode()
        assert result.returncode != 0, "a service started under a shared runtime root"
        assert refused(directory) in error, error
        assert not (Path(runtime) / "airlock").exists(), "AIRLOCK_HOME did not replace XDG_RUNTIME_DIR"
    assert not directory.exists(), "init created a directory under a refused root"


def planted_ca_refused(case):
    """A CA under the shared /tmp, which init refuses, is no more trusted by
    the client or the jail, which read it through its canonical path."""
    directory = ca_directory(case, None)
    created = [path for path in (directory, *directory.parents) if not path.exists()][-1]
    directory.mkdir(mode=0o700, parents=True)
    try:
        for name in ("ca.key", "ca.pem"):
            (directory / name).write_bytes(Path(case["nativeCa"]).read_bytes())
        for client in (case["client"], *jailed_clients(case)):
            result = subprocess.run([client], env=os.environ, capture_output=True, timeout=10)
            error = result.stderr.decode()
            assert result.returncode != 0, "a client trusted a CA another user could plant"
            assert refused(directory) in error, error
    finally:
        shutil.rmtree(created)


def refused_without_runtime(case):
    """Without XDG_RUNTIME_DIR the service keeps its config under TMPDIR, but
    the CA has no fallback, so an intercepting instance refuses to start."""
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        environment = dict(os.environ)
        environment.pop("XDG_RUNTIME_DIR", None)
        environment["TMPDIR"] = directory
        result = subprocess.run([case["launcher"]], env=environment, capture_output=True, timeout=10)
        error = result.stderr.decode()
        assert result.returncode != 0, "a CA was created without XDG_RUNTIME_DIR"
        assert "XDG_RUNTIME_DIR is unset or empty" in error, error
        assert not list(Path(directory).glob("**/ca.key")), "a CA fell back to TMPDIR"


def start_twice(case, live, runtime_variable="XDG_RUNTIME_DIR"):
    """Return the CA certificate each start of one runtime directory used."""
    certificates = []
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        scratch = Path(directory)
        environment = dict(os.environ)
        environment.pop("XDG_RUNTIME_DIR", None)
        environment[runtime_variable] = directory
        name = ("ai-service-airlock-main" if runtime_variable == "XDG_RUNTIME_DIR"
                else f"ai-service-{os.getuid()}-airlock-main")
        runtime = scratch / name
        ca = ca_directory(case, directory)
        with (scratch / "output").open("w+") as output:
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
                    if case["intercepting"]:
                        # serve only loads a CA, so this one came from the
                        # launcher's `airlock ca init --instance main`.
                        private(ca, 0o700)
                        private(ca / "ca.key", 0o600)
                        assert stat.S_IMODE((ca / "ca.pem").stat().st_mode) == 0o644
                        certificates.append((ca / "ca.pem").read_bytes())
                        client_trust(case, environment, ca, scratch)
                        concurrent_clients(case, environment, ca, scratch)
                    else:
                        assert not ca.exists(), "an opaque instance created a CA"
                        client_trust(case, environment, ca, scratch)
                    if case["intercepting"] and live:
                        jail_clients(case, environment, ca, scratch)
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
        if not case["intercepting"]:
            start_twice(case, live)
            start_twice(case, live, "TMPDIR")
        elif case["home"] is not None:
            missing_key_refused(case)
            refused_home(case)
            planted_ca_refused(case)
        else:
            missing_key_refused(case)
            first, restarted = start_twice(case, live)
            assert first.startswith(b"-----BEGIN CERTIFICATE-----")
            assert restarted == first, "a restart replaced the runtime CA"
            assert start_twice(case, live)[0] != first, "a new runtime directory reused a CA"
            refused_without_runtime(case)
        print(f"ok: {case['backend']} intercepting={case['intercepting']}")

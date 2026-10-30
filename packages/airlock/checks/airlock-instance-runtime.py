"""Start each backend's generated launcher: health at the configured port, a
private runtime config, an interception CA kept beside it, and that CA in the
extra-CA file Claude's launcher starts a mock Claude with.

CI runs service/trust checks and missing-key refusals before bubblewrap. The
separate hand-run live check requires all real jailed probes to succeed; CI's
build sandbox cannot execute them. There is no fallback from live to CI mode.
"""

import argparse
import contextlib
import http.client
import json
import os
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
    inherited = Path(environment["XDG_RUNTIME_DIR"]) / "inherited.pem"
    inherited.write_bytes(b"inherited certificate fixture\n")
    status, extra, error = launch_client(case, environment)
    assert status == 0, error
    if not case["intercepting"]:
        assert extra is None, "an opaque selection set an extra CA"
        assert launch_client(case, environment, inherited)[1] == str(inherited)
        return
    override = case | {"client": case["clientOverride"]}
    assert launch_client(override, environment, inherited)[1] == "/user/ca.pem", "native CA did not win"
    ca = (runtime / "ca" / "ca.pem").read_bytes()
    assert Path(extra).read_bytes() == ca
    status, bundle, error = launch_client(case, environment, inherited)
    assert status == 0, error
    assert Path(bundle).read_bytes() == inherited.read_bytes() + b"\n" + ca
    private(Path(bundle), 0o600)
    assert launch_client(case, environment, inherited)[1] == bundle, "a relaunch wrote another bundle"
    status, _, error = launch_client(case, environment, inherited.with_name("missing.pem"))
    assert status != 0, "a missing inherited CA was dropped"
    assert not list(runtime.glob(".trust.*")), "a failed launch left a partial bundle"


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
                assert f"airlock-main: cannot jail client: CA key missing at {key}" in error, error
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


def start_twice(case, live):
    """Return the CA certificate each start of one runtime directory used."""
    certificates = []
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        environment = os.environ | {"XDG_RUNTIME_DIR": directory}
        runtime = Path(directory) / "ai-service-airlock-main"
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
        if case["intercepting"]:
            first, restarted = certificates
            assert first.startswith(b"-----BEGIN CERTIFICATE-----")
            assert restarted == first, "a restart replaced the runtime CA"
            assert start_twice(case, live)[0] != first, "a new runtime directory reused a CA"
        print(f"ok: {case['backend']} intercepting={case['intercepting']}")

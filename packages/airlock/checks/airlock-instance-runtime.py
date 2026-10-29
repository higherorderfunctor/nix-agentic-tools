"""Start each backend's generated launcher: health at the configured port, a
private runtime config, and an interception CA kept beside it."""

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


def start_twice(case):
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
                assert child.returncode == 0, child.returncode
    return certificates


if __name__ == "__main__":
    for case in json.loads(Path(sys.argv[1]).read_text()):
        case["config"] = json.loads(case["config"])
        certificates = start_twice(case)
        if case["intercepting"]:
            first, restarted = certificates
            assert first.startswith(b"-----BEGIN CERTIFICATE-----")
            assert restarted == first, "a restart replaced the runtime CA"
            assert start_twice(case)[0] != first, "a new runtime directory reused a CA"
        print(f"ok: {case['backend']} intercepting={case['intercepting']}")

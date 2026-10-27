"""Check private config/secret/CA wiring through both actual backend launchers."""

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
        if child.poll() is None:
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


def check(case):
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        root = Path(directory)
        token = root / "source-token"
        environment = os.environ | {
            "AIRLOCK_TEST_TOKEN": str(token),
            "INVOCATION_ID": "airlock-runtime-test",
            "XDG_RUNTIME_DIR": directory,
        }
        runtime = root / "ai-service-airlock-main"
        with (root / "output").open("w+") as output:
            if case["authenticated"]:
                with running(case["launcher"], environment, output) as child:
                    assert child.wait(timeout=10) != 0, "missing secret started the service"
                    assert not healthy(case["config"]), "missing secret reached readiness"
                assert not (runtime / "config.json").exists()
                assert not (runtime / "ca").exists()
            certificate = None
            for attempt in range(2):
                # A reader resolves the source again at every start, including rotation.
                expected_token = f"fixture-token-{attempt}:@%".encode()
                token.write_bytes(expected_token + b"\n")
                with running(case["launcher"], environment, output) as child:
                    deadline = time.monotonic() + 10
                    while not healthy(case["config"]):
                        assert child.poll() is None, "service exited before readiness"
                        assert time.monotonic() < deadline, "service readiness timed out"
                        time.sleep(0.02)
                    private(runtime, 0o700)
                    config_path = runtime / "config.json"
                    private(config_path, 0o600)
                    rendered = json.loads(config_path.read_text())
                    assert rendered["listen"] == case["config"]["listen"]
                    if case["authenticated"]:
                        token_path = Path(rendered["clients"]["fixture"]["token_file"])
                        assert token_path.parent == runtime
                        private(token_path, 0o600)
                        assert token_path.read_bytes() == expected_token
                        assert rendered["interception"] == case["config"]["interception"]
                        assert "ca_directory" not in rendered["interception"]
                        ca = runtime / "ca"
                        private(ca, 0o700)
                        private(ca / "ca.key", 0o600)
                        current = (ca / "ca.pem").read_bytes()
                        assert current.startswith(b"-----BEGIN CERTIFICATE-----")
                        if certificate is not None:
                            assert current == certificate, "restart replaced runtime CA"
                        certificate = current
                    else:
                        assert "clients" not in rendered
                        assert "interception" not in rendered
                        assert not (runtime / "ca").exists()
                assert child.returncode == 0, child.returncode
            if case["authenticated"]:
                token.unlink()
                with running(case["launcher"], environment, output) as child:
                    assert child.wait(timeout=10) != 0, "missing rotated secret started service"
                    assert not healthy(case["config"])
        assert b"fixture-token-" not in (root / "output").read_bytes()
        print(f"ok: {case['backend']} authenticated={case['authenticated']}")
        return certificate


if __name__ == "__main__":
    for case in json.loads(Path(sys.argv[1]).read_text()):
        case["config"] = json.loads(case["config"])
        certificate = check(case)
        if case["authenticated"]:
            assert check(case) != certificate, "a fresh runtime reused another runtime's CA"

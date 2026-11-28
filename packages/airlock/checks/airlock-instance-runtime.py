"""Check service wiring through each backend's generated outer launcher."""

import http.client
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def readiness(backend, launcher, listen):
    host, port = listen.rsplit(":", 1)
    port = int(port)
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        environment = os.environ | {"XDG_RUNTIME_DIR": directory}
        with (Path(directory) / "output").open("w+") as output:
            child = subprocess.Popen([launcher], env=environment, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 10
                while True:
                    assert child.poll() is None, f"{backend} service exited before readiness"
                    connection = http.client.HTTPConnection(host, port, timeout=0.5)
                    try:
                        connection.request("GET", "/health")
                        response = connection.getresponse()
                        assert response.status == 200, (backend, response.status)
                        body = response.read()
                        assert body == b"ok\n", (backend, body)
                        break
                    except OSError:
                        assert time.monotonic() < deadline, f"{backend} service readiness timed out"
                        time.sleep(0.02)
                    finally:
                        connection.close()
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
            assert child.returncode == 0, (backend, child.returncode)


if __name__ == "__main__":
    listen, hm, devenv = sys.argv[1:]
    for backend, launcher in [("hm", hm), ("devenv", devenv)]:
        readiness(backend, launcher, listen)

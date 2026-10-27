"""Check service wiring through each backend's generated outer launcher."""

import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def readiness(launcher, config):
    host, port = config["listen"].rsplit(":", 1)
    port = int(port)
    assert port != 8318, "a default port would not prove the config was read"
    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as directory:
        environment = os.environ | {"XDG_RUNTIME_DIR": directory}
        with (Path(directory) / "output").open("w+") as output:
            child = subprocess.Popen([launcher], env=environment, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 10
                while True:
                    assert child.poll() is None, "service exited before readiness"
                    connection = http.client.HTTPConnection(host, port, timeout=0.5)
                    try:
                        connection.request("GET", "/health")
                        response = connection.getresponse()
                        assert response.status == 200, response.status
                        assert response.read() == b"ok\n"
                        break
                    except OSError:
                        assert time.monotonic() < deadline, "service readiness timed out"
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
            assert child.returncode == 0, child.returncode


if __name__ == "__main__":
    config = json.loads(sys.argv[1])
    for launcher in sys.argv[2:]:
        readiness(launcher, config)

"""Run a generated Airlock service launcher and wait for its health route."""

import contextlib
import http.client
import subprocess
import sys
import time


def healthy(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        # A listener that answers wrongly is a failure, not "not ready yet".
        assert response.status == 200, response.status
        assert response.read() == b"ok\n"
        return True
    except OSError:
        return False
    finally:
        connection.close()


def wait_ready(child, port, timeout=10):
    deadline = time.monotonic() + timeout
    while not healthy(port):
        assert child.poll() is None, "service exited before readiness"
        assert time.monotonic() < deadline, "service readiness timed out"
        time.sleep(0.02)


@contextlib.contextmanager
def running(launcher, environment, output, secret=None):
    """Run `launcher`, stopping it on exit; on failure, show its output with
    `secret` masked."""
    child = subprocess.Popen([launcher], env=environment, stdout=output, stderr=output)
    try:
        yield child
    except BaseException:
        output.flush()
        output.seek(0)
        captured = output.read()
        sys.stderr.write(captured if not secret else captured.replace(secret, "<secret>"))
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

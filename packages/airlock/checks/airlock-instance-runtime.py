#!/usr/bin/env python3
import os
import socket
import sys
import subprocess
import tempfile
import threading
import time
from pathlib import Path

PROXY_ADDRESS = ("127.0.0.1", 8318)


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    while size:
        chunk = sock.recv(size)
        if not chunk:
            raise AssertionError("peer closed before sending the expected bytes")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def read_headers(sock: socket.socket) -> bytes:
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(1024)
        if not chunk:
            raise AssertionError(f"Airlock closed before CONNECT response: {response!r}")
        response.extend(chunk)
    return bytes(response)


def connect_to_proxy(process: subprocess.Popen) -> socket.socket:
    deadline = time.monotonic() + 5
    while True:
        try:
            return socket.create_connection(PROXY_ADDRESS, timeout=1)
        except OSError:
            if process.poll() is not None:
                stdout, stderr = process.communicate(timeout=1)
                raise AssertionError(
                    f"Airlock launcher exited with {process.returncode}: "
                    f"stdout={stdout!r}, stderr={stderr!r}"
                ) from None
            if time.monotonic() >= deadline:
                raise AssertionError("Airlock launcher did not listen on 127.0.0.1:8318")
            time.sleep(0.02)


def exercise_launcher(launcher: str) -> None:
    upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    upstream.bind(("127.0.0.1", 0))
    upstream.listen(1)
    upstream_address = upstream.getsockname()

    def serve_upstream() -> None:
        peer, _ = upstream.accept()
        with peer:
            assert recv_exact(peer, 5) == b"proxy"
            peer.sendall(b"reply")

    upstream_thread = threading.Thread(target=serve_upstream, daemon=True)
    upstream_thread.start()

    with tempfile.TemporaryDirectory(prefix="airlock-launcher-") as runtime:
        xdg_runtime = Path(runtime) / "xdg"
        xdg_runtime.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment["XDG_RUNTIME_DIR"] = str(xdg_runtime)
        process = subprocess.Popen(
            [launcher],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout = b""
        stderr = b""
        try:
            with connect_to_proxy(process) as client:
                request = (
                    f"CONNECT {upstream_address[0]}:{upstream_address[1]} "
                    "HTTP/1.1\r\n"
                    f"Host: {upstream_address[0]}:{upstream_address[1]}\r\n\r\n"
                ).encode()
                client.sendall(request)
                response = read_headers(client)
                assert response.startswith(b"HTTP/1.1 200 "), response
                client.sendall(b"proxy")
                assert recv_exact(client, 5) == b"reply"
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
            upstream.close()
            upstream_thread.join(timeout=2)

        assert process.returncode == 0, (process.returncode, stdout, stderr)
        assert b"airlock listening on 127.0.0.1:8318" in stdout, (stdout, stderr)
        assert stderr == b"", stderr
        assert not upstream_thread.is_alive()


def main() -> None:
    for launcher in sys.argv[1:]:
        exercise_launcher(launcher)


if __name__ == "__main__":
    main()

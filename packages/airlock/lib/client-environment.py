"""Print shell exports that point a client at a running Airlock instance.

Reads the instance's private runtime files at exec time: its config, the
selected client's token and, with interception, its CA. Prints shell-quoted
`export` lines for the proxy URL and trust bundle once the instance is ready.
Claude's launcher is the one caller, so the error and cached bundles name it.
"""
# cspell:words ITIMER setitimer

import hashlib
import http.client
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import sys
import tempfile
from urllib.parse import quote_from_bytes

# The token grammar `read_token` in packages/ai/airlock/src/auth.rs enforces:
# 1 to 4096 graphic ASCII bytes, optionally followed by one LF.
MAX_TOKEN_BYTES = 4096
GRAPHIC_ASCII = range(33, 127)
READY_DEADLINE_SECONDS = 2


def fail(message):
    raise ValueError(message)


def private_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        os.close(descriptor)
        fail("runtime directory must be owned by this user with mode 0700")
    return descriptor


def read_file(path, *, directory=None, private=False, limit=16 * 1024 * 1024):
    descriptor = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory
    )
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            fail("required input must be a regular file")
        if private and (
            metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600)
        ):
            fail("private input must be owned by this user with mode 0400 or 0600")
        content = source.read(limit + 1)
        if not content or len(content) > limit:
            fail("required input is empty or too large")
        return content


def read_selected_token(directory, descriptor, config, client):
    selected = config.get("clients", {}).get(client)
    if selected is None:
        fail("selected client is absent from the running service config")
    token_path = Path(selected["token_file"])
    if token_path.parent != directory:
        fail("selected token file must belong to the service runtime directory")
    token = read_file(
        token_path.name, directory=descriptor, private=True, limit=MAX_TOKEN_BYTES + 1
    )
    if token.endswith(b"\n"):
        token = token[:-1]
    if not token or len(token) > MAX_TOKEN_BYTES or any(
        byte not in GRAPHIC_ASCII for byte in token
    ):
        fail("selected token file has invalid contents")
    return token


def proxy_url(client, token, port):
    # Percent-encode every byte, so token punctuation cannot end the userinfo.
    name = quote_from_bytes(client.encode(), safe="")
    password = quote_from_bytes(token, safe="")
    return f"http://{name}:{password}@127.0.0.1:{port}"


def combined_trust(directory, descriptor, inherited, certificate):
    # Existing extra trust can be a system-managed symlink. Resolve it before
    # opening; private service inputs above deliberately refuse symlinks.
    previous = read_file(Path(inherited).resolve(strict=True))
    content = previous + b"\n" + certificate
    name = "claude-extra-ca-" + hashlib.sha256(content).hexdigest() + ".pem"
    target = directory / name
    if target.exists() or target.is_symlink():
        if read_file(name, directory=descriptor, private=True) != content:
            fail("cached extra-CA bundle does not match its inputs")
        return target
    temporary = None
    try:
        file_descriptor, temporary = tempfile.mkstemp(prefix=".claude-ca-", dir=directory)
        with os.fdopen(file_descriptor, "wb") as output:
            output.write(content)
        # Same-directory replacement publishes complete 0600 bytes. Concurrent
        # publishers of this content hash write the same certificate bundle.
        os.replace(temporary, target)
    finally:
        if temporary is not None and os.path.lexists(temporary):
            os.unlink(temporary)
    return target


def trust_bundle(directory, descriptor):
    """The CA file a client should trust: Airlock's CA, added to any inherited one."""
    ca_directory = private_directory(directory / "ca")
    try:
        certificate = read_file("ca.pem", directory=ca_directory)
    finally:
        os.close(ca_directory)
    inherited = os.environ.get("NODE_EXTRA_CA_CERTS")
    if not inherited:
        return directory / "ca" / "ca.pem"
    return combined_trust(directory, descriptor, inherited, certificate)


def read_exports(directory, client, port):
    descriptor = private_directory(directory)
    try:
        config = json.loads(read_file("config.json", directory=descriptor, private=True))
        token = read_selected_token(directory, descriptor, config, client)
        exports = {"HTTPS_PROXY": proxy_url(client, token, port)}
        if config.get("interception") is not None:
            exports["NODE_EXTRA_CA_CERTS"] = str(trust_bundle(directory, descriptor))
        return exports
    finally:
        os.close(descriptor)


def deadline_expired(_signal, _frame):
    raise TimeoutError("Airlock readiness deadline expired")


def require_ready(port):
    # Socket inactivity alone is not a total deadline for a trickling peer.
    signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, READY_DEADLINE_SECONDS)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        if response.status != 200 or response.read(4) != b"ok\n":
            fail("selected service is not ready")
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        connection.close()


def print_exports(exports):
    # These are shell builtins, never external argv. shlex quotes every byte
    # represented in the URL, so token punctuation cannot become shell code.
    for variable, value in exports.items():
        print(f"export {variable}={shlex.quote(value)}")


def main(directory, client, port):
    exports = read_exports(directory, client, port)
    require_ready(port)
    print_exports(exports)


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, http.client.HTTPException):
        # Exception text can contain a malformed document's contents. Keep the
        # diagnostic independent of config, token and inherited trust bytes.
        sys.exit(
            "ai.claude.proxy: Airlock runtime inputs are unavailable or the service is not ready; "
            "start the selected airlock service and check its private config, token and CA files."
        )

"""Explicit OAuth consent with two loopback listeners and locked publication."""

import contextlib
import hmac
import secrets
import selectors
import socket
import subprocess
import time
from urllib.parse import parse_qs, parse_qsl, urlencode, urlsplit, urlunsplit

from oauth import OAuthError, credential, exchange

BROWSER = "@browser@"


def authorities(uri):
    """Host header values a browser may send for the redirect: it omits a default :80."""
    netloc = uri.netloc
    return {netloc, netloc.removesuffix(":80")} if uri.port == 80 else {netloc}


def callback(connection, uri, expected_state):
    """Refuse malformed, oversized or unrelated requests without logging secrets."""
    end = time.monotonic() + 2
    raw = b""
    while b"\r\n\r\n" not in raw and len(raw) <= 8192:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return None
        connection.settimeout(remaining)
        data = connection.recv(min(1024, 8193 - len(raw)))
        if not data:
            break
        raw += data
    try:
        header, body = raw.split(b"\r\n\r\n", 1)
        lines = header.decode("ascii").split("\r\n")
        method, target, version = lines[0].split(" ")
        headers = {}
        for line in lines[1:]:
            key, value = line.split(":", 1)
            key = key.lower()
            if key in headers:
                raise ValueError()
            headers[key] = value.strip()
        request = urlsplit(target)
        query = parse_qs(request.query, strict_parsing=True, max_num_fields=8)
        valid = (len(raw) <= 8192 and not body and method == "GET"
                 and version in ("HTTP/1.0", "HTTP/1.1")
                 and not request.scheme and not request.netloc and not request.fragment
                 and request.path == uri.path and headers.get("host") in authorities(uri)
                 and headers.get("content-length", "0") == "0"
                 and "transfer-encoding" not in headers
                 and len(query.get("state", [])) == 1
                 and hmac.compare_digest(query["state"][0].encode(), expected_state.encode())
                 and len(query.get("code", [])) == 1 and "error" not in query
                 and 0 < len(query["code"][0]) <= 4096)
        if not valid:
            raise ValueError()
    except (KeyError, UnicodeError, ValueError):
        connection.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        return None
    connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 24\r\n\r\nYou may close this tab.\n")
    return query["code"][0]


def login(account, *, browser=BROWSER, clock=time.time, timeout=300):
    redirect = account.config["redirect_uri"]
    uri = urlsplit(redirect)
    scopes = account.config["scopes"]
    state = secrets.token_urlsafe(32)
    provider = account.config["provider"]
    endpoint = urlsplit(provider["authorizeUrl"])
    query = parse_qsl(endpoint.query, keep_blank_values=True)
    query.extend({
        "client_id": credential(account.config["client_id_file"]),
        "redirect_uri": redirect,
        "response_type": "code",
        "scope": " ".join(sorted(set(scopes) | set(provider["extraScopes"]))),
        "state": state,
    }.items())
    url = urlunsplit(endpoint._replace(query=urlencode(query)))
    try:
        with contextlib.ExitStack() as stack:
            selector = stack.enter_context(selectors.DefaultSelector())
            for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
                listener = stack.enter_context(socket.socket(family, socket.SOCK_STREAM))
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if family == socket.AF_INET6:
                    listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                listener.bind((address, uri.port))
                listener.listen(8)
                listener.setblocking(False)
                selector.register(listener, selectors.EVENT_READ)
            # Both sockets are live before handing the URL to the browser.
            subprocess.run([browser, url], check=True, timeout=15,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            end = time.monotonic() + timeout
            code = None
            while code is None:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise OAuthError("login callback timed out")
                for key, _events in selector.select(min(remaining, 1)):
                    with key.fileobj.accept()[0] as connection:
                        try:
                            code = callback(connection, uri, state)
                        except OSError:
                            continue
                    if code is not None:
                        break
        # Consent does not hold the lock. Ordinary refresh cannot invalidate it.
        with account.locked() as store:
            started = clock()
            response = exchange(account.config, {
                "code": code, "grant_type": "authorization_code", "redirect_uri": redirect
            })
            return store.seed(response, started, provider["loginLifetimeDays"])
    except (OSError, subprocess.SubprocessError):
        raise OAuthError("login listener or browser failed") from None

"""Real listeners and lifecycle logic; fake consent, provider, desktop and clock."""

import contextlib
import fcntl
import http.client
from http.server import ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from types import SimpleNamespace
from urllib.parse import parse_qs, urlencode, urlsplit
from unittest.mock import patch

SOURCE, GUM = sys.argv[1:3]
sys.path.insert(0, SOURCE)
import cli
import daemon
import login
from provider import Provider, profile
from oauth import OAuthError
from state import Account

DAY = 86400


def wait_for(predicate, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("fixture deadline")


def executable(path, body):
    path.write_text(f"#!{sys.executable}\n" + body)
    path.chmod(0o700)
    return str(path)


def request(port, address, authority, path):
    connection = http.client.HTTPConnection(address, port, timeout=3)
    connection.request("GET", path, headers={"Host": authority})
    response = connection.getresponse()
    status = response.status
    response.read()
    connection.close()
    return status


def picker_pty(config, keys, expected):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    code = ("import sys; sys.path.insert(0, sys.argv[1]); import cli, json; "
            "print('SELECTED=' + cli.choose(json.loads(sys.argv[2]), None, gum=sys.argv[3]))")
    process = subprocess.Popen([sys.executable, "-c", code, SOURCE, json.dumps(config), GUM],
                               stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal,
                               env=dict(os.environ, TERM="xterm-256color"))
    os.close(slave)
    output = b""
    try:
        end = time.monotonic() + 10
        sent = False
        while time.monotonic() < end:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                output += chunk
                # Answer gum's terminal cursor-position query, then select.
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")
                if b"alpha" in output and not sent:
                    os.write(master, keys)
                    sent = True
            if process.poll() is not None:
                break
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            raise AssertionError(repr(output)) from None
        assert expected.encode() in output, output
        assert all(label.encode() in output for label in (
            "alpha — login required", "corrupt — unavailable", "expired — login required",
            "refresh — refresh required", "rejected — login required", "zeta — ready")), output
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main():
    with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as stack:
        root = Path(temporary)
        for name, text in (("id", "client-private\n"), ("secret", "secret-private\n\n")):
            (root / name).write_text(text)
        provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        stack.callback(provider.server_close)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        stack.callback(provider.shutdown)
        endpoint = f"http://127.0.0.1:{provider.server_port}/token"
        with socket.socket() as port_socket:
            port_socket.bind(("127.0.0.1", 0))
            port = port_socket.getsockname()[1]
        config = {"client_id_file": str(root / "id"), "client_secret_file": str(root / "secret"),
                  "provider": profile(endpoint), "redirect_uri": f"http://localhost:{port}/callback",
                  "scopes": ["messages:read"], "state_dir": str(root / "account")}
        account = Account("fixture", "work", config)
        url_file = root / "url"
        browser = executable(root / "browser", f"import pathlib, sys\npathlib.Path({str(url_file)!r}).write_text(sys.argv[1])\n")
        real_popen = subprocess.Popen
        browser_calls = []

        def effects(command, *args, **kwargs):
            if command[0] == browser:
                browser_calls.append(command)
            else:
                assert command[:2] in ([sys.executable, __file__], [sys.executable, "-c"]), command
            return real_popen(command, *args, **kwargs)

        stack.enter_context(patch.object(subprocess, "Popen", side_effect=effects))
        states = []
        for address in ("127.0.0.1", "::1"):
            url_file.unlink(missing_ok=True)
            errors = []

            def consent():
                try:
                    url = wait_for(lambda: url_file.read_text() if url_file.exists() else None)
                    parsed = parse_qs(urlsplit(url).query)
                    assert parsed["audience"] == ["fixture"]
                    assert "empty=" in url
                    assert parsed["client_id"] == ["client-private"]
                    assert parsed["scope"] == ["keys:read messages:read"]
                    assert parsed["redirect_uri"] == [config["redirect_uri"]]
                    states.append(parsed["state"][0])
                    authority = f"localhost:{port}"
                    query = urlencode({"code": "consent-private", "state": parsed["state"][0]})
                    if address == "127.0.0.1":
                        for host, path, extra in (
                            (authority, "/wrong?" + query, ""),
                            ("attacker.invalid", "/callback?" + query, ""),
                            (authority, "/callback?code=x&state=bad", ""),
                            (authority, "/callback?code=x&state=%E2%98%83", ""),
                            (authority, "/callback?" + query, "Content-Length: 1\r\n"),
                            (authority, "/callback?" + query, "Host: duplicate\r\n"),
                            (authority, "/callback?" + query, "X-Large: " + "x" * 8200 + "\r\n"),
                        ):
                            with socket.create_connection((address, port), timeout=3) as peer:
                                peer.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\n" + extra + "\r\n").encode())
                                assert b"400 Bad Request" in peer.recv(1024)
                    # A normal refresh during the second consent must not reject login.
                    if address == "::1":
                        result = subprocess.run([sys.executable, __file__, SOURCE, GUM,
                                                 json.dumps(config)], capture_output=True)
                        assert result.returncode == 0, result.stderr
                    assert request(port, address, authority, "/callback?" + query) == 200
                except BaseException as error:
                    errors.append(error)

            worker = threading.Thread(target=consent)
            worker.start()
            seeded = login.login(account, browser=browser, timeout=5)
            worker.join()
            assert not errors, errors
            assert seeded["login_deadline"] == seeded["login_started_at"] + 30 * DAY
            assert Provider.grants[-1]["redirect_uri"] == [config["redirect_uri"]]
            assert Provider.grants[-1]["client_secret"] == ["secret-private"]
        assert states[0] != states[1] and len(states[0]) >= 32

        # Occupy IPv6 only: login must release its already bound IPv4 socket.
        url_file.unlink()
        with socket.socket(socket.AF_INET6) as conflict:
            conflict.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            conflict.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            conflict.bind(("::1", port))
            conflict.listen(1)
            try:
                login.login(account, browser=browser, timeout=0.1)
                raise AssertionError("bind conflict accepted")
            except OAuthError as error:
                assert str(error) == "login listener or browser failed"
            assert not url_file.exists()
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", port))
        try:
            login.login(account, browser=browser, timeout=0.1)
            raise AssertionError("unbounded callback wait")
        except OAuthError as error:
            assert str(error) == "login callback timed out"
        for redirect, host, accepted in (
            ("http://localhost:80/callback", "localhost", True),
            ("http://localhost:80/callback", "localhost:80", True),
            ("http://[::1]:80/callback", "[::1]", True),
            ("http://localhost:8080/callback", "localhost", False),
            ("http://localhost:80/callback", "localhost:8080", False),
        ):
            server, client = socket.socketpair()
            with server, client:
                client.sendall(f"GET /callback?state=s&code=c HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
                result = login.callback(server, urlsplit(redirect), "s")
            assert (result is not None) == accepted, (redirect, host, result)

        choices = {"backend": "fixture", "accounts": {name: dict(config, state_dir=str(root / name))
                                                     for name in ("zeta", "alpha")}}
        assert cli.choose(choices, "zeta") == "zeta"
        assert cli.choose({"backend": "fixture", "accounts": {"only": config}}, None) == "only"
        for value, message in (({"backend": "fixture", "accounts": {}}, "no accounts"),
                               (choices, "multiple accounts")):
            try:
                cli.choose(value, None)
                raise AssertionError("missing picker refusal")
            except OAuthError as error:
                assert message in str(error)
        for name, changes in (("expired", {"access_expires_at": 0, "login_deadline": 1, "refresh_expires_at": 1}),
                              ("refresh", {"access_expires_at": 0}), ("rejected", {"login_required": True}), ("zeta", {})):
            choices["accounts"][name] = dict(config, state_dir=str(root / name))
            fixture = Account("fixture", name, choices["accounts"][name])
            with fixture.locked() as store:
                current = store.seed({key: seeded[key] for key in (
                    "access_token", "expires_in", "refresh_token", "refresh_token_expires_in", "scope", "token_type")}, 0 if name == "expired" else time.time(), 30)
                store.publish(dict(current, **changes))
            (root / name / "lock").unlink()
            (root / name / "access-token").unlink(missing_ok=True)
        choices["accounts"]["corrupt"] = dict(config, state_dir=str(root / "corrupt"))
        (root / "corrupt").mkdir(mode=0o700)
        (root / "corrupt" / "state.json").write_text("corrupt-state")
        (root / "corrupt" / "state.json").chmod(0o600)
        before = {str(path.relative_to(root)): path.read_bytes() if path.is_file() else None for path in root.rglob("*")}
        picker_pty(choices, b"\r", "SELECTED=alpha")
        picker_pty(choices, b"\x1b[B\r", "SELECTED=corrupt")
        picker_pty(choices, b"\x03", "account selection cancelled")
        assert not (root / "alpha").exists()
        assert {str(path.relative_to(root)): path.read_bytes() if path.is_file() else None for path in root.rglob("*")} == before
        print("PASS real gum PTY sorted labels, exact IDs, cancellation without state writes; zero/one/explicit/non-TTY")

        assert len(browser_calls) == 3
        # Real daemon/state/refresh/notify on the main thread; only time and transport are fake.
        now = seeded["login_started_at"]
        response = {key: seeded[key] for key in ("access_token", "expires_in", "refresh_token",
                    "refresh_token_expires_in", "scope", "token_type")}
        notices, observed = [], []
        response["expires_in"] = 4 * DAY
        Provider.body = response
        with account.locked() as store:
            store.seed(response, now, 30)
        baseline = len(Provider.grants)
        moments = [0, 4, 1, 20, 20, 24, 25, 31, 31, 31, 31, 35, 35, 35, 35, 39, 59, 59, 63, 67, 67]
        # Counts are relative to the two explicit logins and consent-time refresh.
        expected_calls = [0, 1, 1, 2, 2, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 7, 7, 8, 9, 9]
        class Trace:
            index = 0

            def is_set(self):
                return self.index == len(moments)

            def set(self):
                self.index = len(moments)

            def wait(self, _seconds):
                if self.index == 6:
                    account.refresh(clock=lambda: now + 25 * DAY)
                with account.locked() as store:
                    current = store.reconcile()
                    assert len(Provider.grants) - baseline == expected_calls[self.index]
                    if self.index in (5, 6):
                        assert current["expiry_warning_at"] == now
                        assert current["login_deadline"] == now + 30 * DAY
                    if self.index in (7, 8, 9, 12, 13):
                        assert current["login_required"] and not (Path(config["state_dir"]) / "access-token").exists()
                    if self.index in (9, 13):
                        store.seed(response, now + moments[self.index] * DAY, 30)
                        assert store.reconcile().get("expiry_warning_at") is None
                    if self.index == 16:
                        assert current["expiry_warning_at"] == now + 35 * DAY
                    if self.index >= 17:
                        assert current["login_deadline"] is None and current["refresh_expires_at"] is None
                        assert "expiry_warning_at" not in current
                        assert current["login_required"] == (self.index >= 19)
                    observed.append((len(Provider.grants) - baseline, len(notices)))
                    if self.index == 16:
                        # A new login without either bound must still refresh and handle rejection.
                        config["provider"]["loginLifetimeDays"] = None
                        response.pop("refresh_token_expires_in")
                        store.seed(response, now + 59 * DAY, None)
                self.index += 1
                Provider.unavailable = self.index in (3, 4)
                Provider.reject = self.index in (11, 19)

        trace = Trace()
        real_run = subprocess.run

        def transport(command, **kwargs):
            if command[0] == "/fixture/notifier":
                notices.append(command[2])
                raise OSError("desktop unavailable")
            return real_run(command, **kwargs)

        diagnostics = io.StringIO()
        with patch.object(daemon, "threading", SimpleNamespace(Event=lambda: trace)), \
             patch.object(subprocess, "run", side_effect=transport), \
             contextlib.redirect_stderr(diagnostics):
            daemon.run(account, "/fixture/backend-wrapper",
                       clock=lambda: now + moments[trace.index] * DAY,
                       notifier="/fixture/notifier", jitter=lambda _low, _high: 1)
        assert len(browser_calls) == 3
        assert observed == list(zip(expected_calls, [0, 0, 0, 0, 0, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5]))
        assert sum("seven days" in notice for notice in notices) == 2
        assert sum("Login required" in notice for notice in notices) == 3
        diagnostic = diagnostics.getvalue()
        assert diagnostic.count("desktop notification failed") == 5
        assert diagnostic.count("refresh unavailable") == 3
        assert "/fixture/backend-wrapper login work" in diagnostic
        for secret in ("client-private", "secret-private", "refresh-private", "consent-private", "access-"):
            assert secret not in diagnostic
        print("PASS bounded and no-deadline daemon refresh, fixed consent, warnings and invalid_grant recovery")
        assert daemon.recovery("/backend path/tool", "account's") == "'/backend path/tool' login 'account'\"'\"'s'"



if len(sys.argv) > 3:
    account = Account("fixture", "work", json.loads(sys.argv[3]))
    with patch.object(subprocess, "Popen", side_effect=AssertionError("refresh launched a subprocess")):
        account.refresh()

else:
    main()

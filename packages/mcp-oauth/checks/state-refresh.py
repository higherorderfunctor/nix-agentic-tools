# cspell:ignore fsyncs
"""Real disk/process/HTTP contracts; no live credentials or provider requests."""

import json
import multiprocessing
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, sys.argv.pop(1))
BINARY = sys.argv.pop(1)
PROCESSES = multiprocessing.get_context("fork")

from provider import profile, provider, response
from oauth import OAuthError
from state import Account

RESPONSE = response()


def killed_publish(account, boundary, connection, reject=False):
    original = os.fsync
    count = 0

    def stop(fd):
        nonlocal count
        original(fd)
        count += 1
        if count == boundary:
            connection.send("at-fsync")
            signal.pause()

    with account.locked() as store:
        current = store.reconcile()
        with patch("state.os.fsync", stop):
            if reject:
                store.reject(current)
            else:
                store.seed(RESPONSE, 0, account.config["provider"]["loginLifetimeDays"])


def refresh_child(account, connection):
    try:
        result = account.refresh(clock=lambda: 1987200)
        connection.send(result["refresh_token"])
    except Exception as error:
        connection.send(f"{type(error).__name__}: {error}")


class StateRefresh(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {
            "client_id_file": str(self.root / "client-id"),
            "client_secret_file": str(self.root / "client-secret"),
            "provider": profile(),
            "state_dir": str(self.root / "account"),
        }
        Path(self.config["client_id_file"]).write_text("integration-id\r\n")
        Path(self.config["client_secret_file"]).write_text("integration-secret\n")
        self.account = Account("devenv:/project", "work", self.config)
        self.seed()

    def seed(self, response=None):
        with self.account.locked() as store:
            store.seed(dict(RESPONSE, access_token="access-old") if response is None else response, 0, self.config["provider"]["loginLifetimeDays"])

    def read(self):
        with self.account.locked() as store:
            return store.reconcile()

    def test_day23_same_token_preserves_fields_and_hard_deadline(self):
        """Persist all returned fields and trim secret line endings without extending consent."""
        with provider() as (endpoint, calls):
            self.config["provider"]["tokenUrl"] = endpoint
            result = self.account.refresh(clock=lambda: 1987200)
        self.assertEqual(result["login_started_at"], 0)
        self.assertEqual(result["login_deadline"], 2592000)
        self.assertEqual(result["refresh_expires_at"], 4579200)
        self.assertEqual(result["access_expires_at"], 3196800)
        for key, expected in RESPONSE.items():
            self.assertEqual(result[key], expected)
        self.assertEqual(calls, [("/v1/access_token", {
            "client_id": ["integration-id"], "client_secret": ["integration-secret"],
            "grant_type": ["refresh_token"], "refresh_token": ["refresh-original"]
        }, "application/x-www-form-urlencoded")])
        self.assertEqual(self.account.status(clock=lambda: 1987200),
                         "ready; login expires in 7 days; warning: renew login soon")
        self.assertEqual((self.root / "account/access-token").read_bytes(), b"access-new")
        self.assertEqual(self.read(), result)

    def test_status_reports_shorter_refresh_expiry(self):
        """Reject status counting down from the fixed profile deadline when a refresh reported a shorter life."""
        self.seed(RESPONSE)
        with provider(dict(RESPONSE, refresh_token_expires_in=172800)) as (url, _):
            self.config["provider"]["tokenUrl"] = url
            self.account.refresh(clock=lambda: 0)
        self.assertEqual(self.account.status(clock=lambda: 0), "ready; login expires in 2 days; warning: renew login soon")

    def test_optional_refresh_expiry_and_fixed_login_lifetime(self):
        """Reject required extension fields, erased known expiry and refresh extending consent."""
        absent = {key: value for key, value in RESPONSE.items() if key != "refresh_token_expires_in"}
        for scenario, lifetime, deadline in (
            ("missing refresh expiry leaves fixed bound intact", 30, 2592000),
            ("no bounds must not acquire an invented deadline", None, None),
        ):
            with self.subTest(scenario=scenario):
                self.config["provider"]["loginLifetimeDays"] = lifetime
                self.seed(absent)
                self.assertEqual(self.read()["login_deadline"], deadline)
                self.assertIsNone(self.read()["refresh_expires_at"])
                with provider(absent) as (url, _):
                    self.config["provider"]["tokenUrl"] = url
                    current = self.account.refresh(clock=lambda: 100)
                self.assertEqual(current["login_deadline"], deadline)
                self.assertIsNone(current["refresh_expires_at"])
                self.assertNotIn("refresh_token_expires_in", current)
                if lifetime is None:
                    self.assertEqual(self.account.status(clock=lambda: 100), "ready; no known login expiry")
                self.seed(dict(RESPONSE, refresh_token_expires_in=172800))
                with provider(absent) as (url, _):
                    self.config["provider"]["tokenUrl"] = url
                    current = self.account.refresh(clock=lambda: 100)
                self.assertEqual(current["refresh_expires_at"], 172800)
                self.assertEqual(current["login_deadline"], deadline)
        # Changing profile lifetime never changes the bound of an existing login.
        self.config["provider"]["loginLifetimeDays"] = 30
        self.seed(absent)
        self.config["provider"]["loginLifetimeDays"] = None
        with provider() as (url, _):
            self.config["provider"]["tokenUrl"] = url
            current = self.account.refresh(clock=lambda: 1987200)
        self.assertEqual(current["login_deadline"], 2592000)
        self.assertEqual(current["refresh_expires_at"], 4579200)
        self.assertEqual(self.account.status(clock=lambda: 2592000), "login required; login has expired")

    def test_scheduled_waiting_checks_expiry_before_due(self):
        """Scheduled waiting must not exchange or hide an expired login."""
        self.seed(dict(RESPONSE, expires_in=200, refresh_token_expires_in=100))
        with provider() as (url, calls):
            self.config["provider"]["tokenUrl"] = url
            for scenario, now, required in (
                ("early refresh leaves a live login ready", 50, False),
                ("exact expiry invalidates login before the due time", 100, True),
            ):
                with self.subTest(scenario=scenario):
                    current = self.account.refresh(clock=lambda: now,
                                                   due_at=lambda current: current["access_expires_at"])
                    self.assertEqual(current["login_required"], required)
            self.assertEqual(calls, [])
        self.assertTrue(self.read()["login_required"])
        self.assertFalse((self.root / "account/access-token").exists())
        with self.assertRaisesRegex(OAuthError, "login required"):
            self.account.refresh(clock=lambda: 101)
        # A daemon without any state can wait, while an explicit refresh fails.
        missing = Account("devenv:/project", "missing",
                          dict(self.config, state_dir=str(self.root / "missing")))
        self.assertIsNone(missing.refresh(due_at=lambda current: 0))
        with self.assertRaisesRegex(OAuthError, "login required"):
            missing.refresh()

    def test_rotation_serialized_across_processes(self):
        """Reject stale pre-lock reads; rotation is synthetic, not a provider guarantee."""
        with provider(dict(RESPONSE, refresh_token="refresh-rotated")) as (url, calls):
            self.config["provider"]["tokenUrl"] = url
            pairs = [PROCESSES.Pipe() for _ in range(2)]
            children = [PROCESSES.Process(target=refresh_child, args=(self.account, pair[1]))
                        for pair in pairs]
            try:
                for child in children:
                    child.start()
                for child, (parent, _) in zip(children, pairs):
                    child.join(5)
                    self.assertFalse(child.is_alive(), "refresh did not release the account lock")
                    self.assertTrue(parent.poll(1))
                    self.assertEqual(parent.recv(), "refresh-rotated")
            finally:
                for child, (parent, pipe) in zip(children, pairs):
                    if child.is_alive():
                        child.kill()
                        child.join(5)
                    parent.close()
                    pipe.close()
            self.assertEqual([call[1]["refresh_token"] for call in calls],
                             [["refresh-original"], ["refresh-rotated"]])
        self.assertEqual(self.read()["refresh_token"], "refresh-rotated")

    def test_crash_boundaries_and_invalid_grant(self):
        """Real SIGKILL preserves state-first publication and durable rejection."""
        lock, projection = self.root / "account/lock", self.root / "account/access-token"
        inode = lock.stat().st_ino
        # Projection bytes before recovery and after reopening are protocol
        # expectations, not conditions derived from the implementation's fsyncs.
        cases = (
            ("seed must not publish before state rename", False, 1, b"access-old", False, b"access-old"),
            ("seed must recover after durable state rename", False, 2, b"access-old", False, b"access-new"),
            ("seed must not publish an unfinished projection", False, 3, b"access-old", False, b"access-new"),
            ("seed retains completed projection after crash", False, 4, b"access-new", False, b"access-new"),
            ("rejection must not withdraw before state rename", True, 1, b"access-old", False, b"access-old"),
            ("durable rejection must withdraw on reopen", True, 2, b"access-old", True, None),
            ("completed withdrawal cannot resurrect", True, 3, None, True, None),
        )
        for scenario, reject, boundary, before, required, after in cases:
            with self.subTest(scenario=scenario):
                self.seed()
                parent, child_pipe = PROCESSES.Pipe()
                child = PROCESSES.Process(target=killed_publish, args=(self.account, boundary, child_pipe, reject))
                child.start()
                try:
                    self.assertTrue(parent.poll(5), "writer never reached kill point")
                    parent.recv()
                    self.assertEqual(projection.read_bytes() if projection.exists() else None, before)
                finally:
                    child.kill()
                    child.join(5)
                    parent.close()
                    child_pipe.close()
                self.assertEqual(child.exitcode, -signal.SIGKILL)
                self.assertEqual(self.read()["login_required"], required)
                self.assertEqual(projection.read_bytes() if projection.exists() else None, after)
                self.assertEqual(lock.stat().st_ino, inode)
        self.assertEqual((self.root / "account").stat().st_mode & 0o777, 0o700)
        for path in (self.root / "account").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.seed()
        with provider({"error": "invalid_grant"}, 400) as (url, _):
            self.config["provider"]["tokenUrl"] = url
            with self.assertRaisesRegex(OAuthError, "login required"):
                self.account.refresh(clock=lambda: 1)
        self.assertTrue(self.read()["login_required"])
        self.assertFalse((self.root / "account/access-token").exists())

    def test_unusable_state_refused_where_read(self):
        """Refuse malformed deadlines and unsafe file permissions when loading state."""
        path = self.root / "account/state.json"
        original = path.read_bytes()
        try:
            value = json.loads(original)
            value["login_started_at"] = 1
            value["login_deadline"] = 10368000
            value["refresh_expires_at"] = None
            path.write_text(json.dumps(value))
            self.assertEqual(self.read()["login_deadline"], 10368000)
            for scenario, invalid, message in (
                ("deadline cannot precede the login", 0, "invalid login deadline"),
                ("deadline cannot be text", "unknown", "invalid lifetime or timestamp"),
            ):
                with self.subTest(scenario=scenario):
                    path.write_text(json.dumps(dict(value, login_deadline=invalid)))
                    with self.assertRaisesRegex(OAuthError, message):
                        self.read()
            path.write_bytes(original)
            path.chmod(0o644)
            with self.assertRaisesRegex(OAuthError, "unsafe account state ownership, type or permissions"):
                self.read()
        finally:
            path.write_bytes(original)
            path.chmod(0o600)

    def test_bad_responses_leave_authoritative_state_unchanged(self):
        """Reject missing refresh_token, malformed tokens and invented lifetimes."""
        before = self.read()
        cases = (
            ("header token cannot contain a newline", dict(RESPONSE, access_token="bad\n"), "invalid token syntax"),
            ("access lifetime cannot be negative", dict(RESPONSE, expires_in=-1), "invalid lifetime or timestamp"),
            ("access lifetime cannot be a boolean", dict(RESPONSE, expires_in=True), "invalid lifetime or timestamp"),
            ("provider expiry cannot be unbounded", dict(RESPONSE, refresh_token_expires_in=float("inf")),
             "invalid lifetime or timestamp"),
            ("scope cannot be null", dict(RESPONSE, scope=None), "invalid scope"),
            ("response must supply a Bearer token", dict(RESPONSE, token_type="MAC"), "unsupported token type"),
            ("refresh token is required", {key: value for key, value in RESPONSE.items() if key != "refresh_token"},
             "incomplete token response"),
        )
        for scenario, body, message in cases:
            with self.subTest(scenario=scenario), provider(body) as (url, _):
                self.config["provider"]["tokenUrl"] = url
                with self.assertRaisesRegex(OAuthError, message):
                    self.account.refresh(clock=lambda: 1)
                self.assertEqual(self.read(), before)

    def test_credentials_refused_before_exchange(self):
        """Reject empty or embedded-newline credentials before provider calls."""
        path = Path(self.config["client_secret_file"])
        for scenario, bad in (
            ("empty after trimming trailing line endings", "\r\n"),
            ("embedded line feed", "secret\nmore"),
            ("embedded carriage return", "secret\rmore"),
        ):
            with self.subTest(scenario=scenario), provider() as (url, calls):
                path.write_text(bad)
                self.config["provider"]["tokenUrl"] = url
                with self.assertRaisesRegex(OAuthError, "empty or multiline credential"):
                    self.account.refresh(clock=lambda: 1)
                self.assertEqual(calls, [])

    def test_packaged_cli_expired_status_corrupt_state_and_secret_free_output(self):
        """Check packaged expired-state status, corrupt-state refusal and secret-free output."""
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"accounts": {"work": self.config}, "backend": "devenv:/project"}))
        def run(*args):
            return subprocess.run([BINARY, *args], capture_output=True, text=True, timeout=5)
        result = run("--manifest", str(manifest), "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("login required; login has expired", result.stdout)
        self.assertNotIn("access-old", result.stdout + result.stderr)
        state = self.root / "account/state.json"
        state.write_text("not json")
        result = run("--manifest", str(manifest), "status")
        self.assertEqual(result.returncode, 1)
        self.assertIn("corrupt account state", result.stderr)
        self.assertNotIn("access-old", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

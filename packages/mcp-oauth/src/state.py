"""Locked account state is authoritative; access-token is its recoverable projection."""

import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import secrets
import stat
import time

from oauth import DAY, InvalidGrant, OAuthError, exchange, number, validate_response


def private(info, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    mode = 0o700 if directory else 0o600
    if (not kind(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != mode or (not directory and info.st_nlink != 1)):
        raise OAuthError("unsafe account state ownership, type or permissions")


def effective_expiry(current):
    bounds = [current[key] for key in ("login_deadline", "refresh_expires_at") if current[key] is not None]
    return min(bounds, default=None)


def login_required(current, now):
    expiry = effective_expiry(current)
    return current["login_required"] or (expiry is not None and now >= expiry)


def format_status(current, now):
    if current is None:
        return "login required (no state)"
    label = "login required" if login_required(current, now) else (
        "refresh required" if now >= current["access_expires_at"] else "ready")
    expiry = effective_expiry(current)
    if expiry is None:
        return f"{label}; no known login expiry"
    if now >= expiry:
        return f"{label}; login has expired"
    remaining = math.ceil((expiry - now) / DAY)
    warning = "; warning: renew login soon" if expiry - now <= 7 * DAY else ""
    return f"{label}; login expires in {remaining} days{warning}"


def open_directory(path, *, create=True):
    # Walk with directory descriptors so no component can redirect state via a
    # symlink. Ancestors may be shared; the account directory must be private.
    parts = Path(path).parts
    if not Path(path).is_absolute() or ".." in parts or len(parts) < 2:
        raise OAuthError("state directory must be an absolute non-root path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                    os.fsync(fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        private(os.fstat(fd), directory=True)
        return fd
    except BaseException:
        os.close(fd)
        raise


class Account:
    def __init__(self, backend, name, config):
        self.backend, self.name, self.config = backend, name, config

    @contextlib.contextmanager
    def locked(self):
        directory = open_directory(self.config["state_dir"])
        try:
            lock = os.open("lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
            try:
                private(os.fstat(lock))
                fcntl.flock(lock, fcntl.LOCK_EX)
                yield Store(directory, self.backend, self.name)
            finally:
                os.close(lock)
        finally:
            os.close(directory)

    def refresh(self, *, clock=time.time, due_at=None):
        with self.locked() as store:
            current = store.reconcile()
            if current is None or current["login_required"]:
                if due_at is not None:
                    return current
                raise OAuthError("login required")
            started = clock()
            if login_required(current, started):
                store.reject(current)
                if due_at is not None:
                    return dict(current, login_required=True)
                raise OAuthError("login required")
            if due_at is not None and started < due_at(current):
                return current
            try:
                response = exchange(self.config, {
                    "grant_type": "refresh_token", "refresh_token": current["refresh_token"]
                })
            except InvalidGrant:
                store.reject(current)
                raise
            updated = dict(current, **response)
            updated["access_expires_at"] = started + response["expires_in"]
            if "refresh_token_expires_in" in response:
                updated["refresh_expires_at"] = started + response["refresh_token_expires_in"]
            store.publish(updated)
            return updated

    def status(self, *, clock=time.time):
        with self.locked() as store:
            current = store.reconcile()
            return format_status(current, clock())

    def picker_status(self, *, clock=time.time):
        try:
            try:
                directory = open_directory(self.config["state_dir"], create=False)
            except FileNotFoundError:
                return format_status(None, clock())
            try:
                current = Store(directory, self.backend, self.name).load()
                return format_status(current, clock())
            finally:
                os.close(directory)
        except (OAuthError, OSError, RecursionError, ValueError):
            return "unavailable"


class Store:
    def __init__(self, directory, backend, name):
        self.directory, self.backend, self.name = directory, backend, name

    def read(self, name):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.directory)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "rb") as stream:
            private(os.fstat(stream.fileno()))
            raw = stream.read(65537)
            if len(raw) > 65536:
                raise OAuthError("account state too large")
            return raw

    def validate(self, value):
        if not isinstance(value, dict):
            raise OAuthError("invalid account state")
        try:
            if type(value["version"]) is not int or value["version"] != 1 or value["backend"] != self.backend or value["account"] != self.name:
                raise OAuthError("account state binding mismatch")
            validate_response(value)
            if type(value["login_required"]) is not bool:
                raise OAuthError("invalid login status")
            for key in ("access_expires_at", "login_started_at"):
                number(value[key])
            for key in ("login_deadline", "refresh_expires_at"):
                if value[key] is not None:
                    number(value[key])
                    if value[key] < value["login_started_at"]:
                        raise OAuthError("invalid login deadline")
        except KeyError:
            raise OAuthError("incomplete account state") from None
        return value

    def atomic(self, name, data):
        if len(data) > 65536:
            raise OAuthError("account state too large")
        # Inspect the destination before replacement, including its owner/mode.
        self.read(name)
        temporary = "." + name + "." + secrets.token_hex(12)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, name, src_dir_fd=self.directory, dst_dir_fd=self.directory)
            os.fsync(self.directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=self.directory)
            except FileNotFoundError:
                pass

    def withdraw(self):
        self.read("access-token")
        try:
            os.unlink("access-token", dir_fd=self.directory)
        except FileNotFoundError:
            pass
        os.fsync(self.directory)

    def load(self):
        raw = self.read("state.json")
        if raw is None:
            return None
        try:
            current = self.validate(json.loads(raw))
        except (RecursionError, ValueError, UnicodeError):
            raise OAuthError("corrupt account state") from None
        return current

    def reconcile(self):
        current = self.load()
        if current is None:
            self.withdraw()
            return None
        projected = self.read("access-token")
        if current["login_required"]:
            self.withdraw()
        elif projected != current["access_token"].encode("ascii"):
            self.atomic("access-token", current["access_token"].encode("ascii"))
        return current

    def publish(self, value):
        self.validate(value)
        self.atomic("state.json", json.dumps(value, sort_keys=True).encode("utf-8"))
        self.reconcile()

    def reject(self, current):
        # A crash before durable rejection can republish the old token. The
        # upstream remains responsible for expiry/revocation; there is no journal.
        self.publish(dict(current, login_required=True))

    def seed(self, response, started, lifetime_days):
        deadline = None if lifetime_days is None else started + lifetime_days * DAY
        value = dict(
            response,
            access_expires_at=started + response["expires_in"],
            account=self.name,
            backend=self.backend,
            login_deadline=deadline,
            login_required=False,
            login_started_at=started,
            refresh_expires_at=(started + response["refresh_token_expires_in"]
                                if "refresh_token_expires_in" in response else None),
            version=1,
        )
        self.publish(value)
        return value

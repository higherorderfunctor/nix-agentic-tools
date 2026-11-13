"""OAuth token exchange: bounded credential reads and HTTP, without secret diagnostics."""

import contextlib
import http.client
import json
import math
import os
import re
import signal
import stat
import urllib.error
import urllib.parse
import urllib.request

DAY = 86400


class OAuthError(Exception):
    """A diagnostic safe to show without request/response details."""


class InvalidGrant(OAuthError):
    pass


def token(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", value):
        raise OAuthError("invalid token syntax")
    return value


def number(value):
    try:
        valid = type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        valid = False
    if not valid:
        raise OAuthError("invalid lifetime or timestamp")
    return value


def validate_response(value):
    if not isinstance(value, dict):
        raise OAuthError("invalid token response")
    try:
        for key in ("access_token", "refresh_token"):
            token(value[key])
        number(value["expires_in"])
        if "refresh_token_expires_in" in value:
            number(value["refresh_token_expires_in"])
        if not isinstance(value["scope"], str) or not re.fullmatch(
            r"[\x21\x23-\x5b\x5d-\x7e]+(?: [\x21\x23-\x5b\x5d-\x7e]+)*", value["scope"]
        ):
            raise OAuthError("invalid scope")
        if not isinstance(value["token_type"], str) or value["token_type"].lower() != "bearer":
            raise OAuthError("unsupported token type")
    except KeyError:
        raise OAuthError("incomplete token response") from None
    return {key: value[key] for key in (
        "access_token", "expires_in", "refresh_token", "refresh_token_expires_in", "scope", "token_type"
    ) if key in value}


@contextlib.contextmanager
def deadline(seconds):
    # CLI exchange runs on the main thread. ITIMER_REAL also interrupts DNS and
    # credential I/O; a socket idle timeout alone cannot bound a dripping peer.
    def expired(_signum, _frame):
        raise OAuthError("token exchange deadline exceeded")

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def credential(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise OAuthError("credential is not a regular file")
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise OAuthError("credential too large")
    value = raw.decode("utf-8").rstrip("\r\n")
    if not value or any(c in value for c in "\r\n\x00"):
        raise OAuthError("empty or multiline credential")
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise OAuthError("token endpoint redirected")


def exchange(account, grant, *, timeout=30):
    try:
        with deadline(timeout):
            form = dict(grant)
            form["client_id"] = credential(account["client_id_file"])
            form["client_secret"] = credential(account["client_secret_file"])
            request = urllib.request.Request(
                account["provider"]["tokenUrl"],
                data=urllib.parse.urlencode(form).encode("ascii"),
                headers={"Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"},
                method="POST",
            )
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            try:
                response = opener.open(request, timeout=timeout)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                raw = response.read(65537)
                if len(raw) > 65536:
                    raise OAuthError("token response too large")
                body = json.loads(raw)
                if response.status in (400, 401) and isinstance(body, dict) and body.get("error") == "invalid_grant":
                    raise InvalidGrant("login required")
                if response.status != 200:
                    raise OAuthError("token endpoint refused exchange")
                return validate_response(body)
    except (http.client.HTTPException, OSError, RecursionError, ValueError, urllib.error.URLError):
        raise OAuthError("token exchange failed") from None

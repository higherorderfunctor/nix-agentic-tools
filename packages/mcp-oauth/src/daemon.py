"""A living refresh loop: expected login failures wait for new durable state."""

import random
import shlex
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from oauth import DAY, OAuthError
from state import effective_expiry, login_required

NOTIFIER = "@notifier@"


def recovery(wrapper, name):
    if not Path(wrapper).is_absolute():
        raise OAuthError("backend wrapper must supply an absolute recovery path")
    return shlex.join([wrapper, "login", name])


def notify(message, *, notifier=NOTIFIER):
    print(f"mcp-oauth: {message}", file=sys.stderr, flush=True)
    try:
        subprocess.run([notifier, "MCP OAuth", message], check=True, timeout=5,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        print("mcp-oauth: desktop notification failed", file=sys.stderr, flush=True)


def refresh_at(current):
    return current["access_expires_at"] - min(3600, current["expires_in"] / 10)


def run(account, wrapper, *, clock=time.time, jitter=random.uniform,
        notifier=NOTIFIER):
    command = recovery(wrapper, account.name)
    stop = threading.Event()
    previous_handlers = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, lambda *_args: stop.set())
    last_transition = None
    failures = 0
    retry_at = 0
    last_clock = clock()
    last_login = None
    try:
        while not stop.is_set():
            now = clock()
            current = None
            try:
                with account.locked() as store:
                    current = store.reconcile()
                login_id = None if current is None else current["login_started_at"]
                if login_id != last_login or now < last_clock:
                    retry_at = 0
                    failures = 0
                last_login, last_clock = login_id, now
                if now >= retry_at:
                    current = account.refresh(clock=clock, due_at=refresh_at)
                    failures = 0
                    retry_at = 0
                required = (current is None or login_required(current, now))
                transition = (login_id, "login required" if required else "ready")
                if required and transition != last_transition:
                    notify(f"Login required: {command}", notifier=notifier)
                last_transition = transition
                warning = False
                if not required:
                    with account.locked() as store:
                        latest = store.reconcile()
                        if (latest is not None and not latest["login_required"]
                                and effective_expiry(latest) is not None
                                and effective_expiry(latest) - now <= 7 * DAY
                                and latest.get("expiry_warning_at") != latest["login_started_at"]):
                            store.publish(dict(latest, expiry_warning_at=latest["login_started_at"]))
                            warning = True
                if warning:
                    notify(f"Login expires within seven days: {command}", notifier=notifier)
            except (OAuthError, OSError, ValueError):
                # invalid_grant is persisted by shared refresh. Reconcile next
                # iteration to notify its transition without restarting.
                failures = min(failures + 1, 8)
                delay = min(300, 2 ** failures) * jitter(0.75, 1.25)
                retry_at = clock() + delay
                if failures == 1:
                    print(f"mcp-oauth: refresh unavailable; recovery: {command}", file=sys.stderr, flush=True)
            wait_seconds = 60
            if current is not None and not current["login_required"]:
                wake = max(retry_at, refresh_at(current))
                wait_seconds = min(wait_seconds, max(0.05, wake - clock()))
            stop.wait(wait_seconds)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

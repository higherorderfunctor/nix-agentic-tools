#!/usr/bin/env python3
"""An ACP host that answers the engine's auth callback, so fixtures run headless.

WHY THIS EXISTS: the engine's `selectAuthProvider` picks one of five providers,
and the launcher passes `--auth=acp-callback` — which delegates auth to the ACP
CLIENT via a `_kiro/auth/getAccessToken` request. Answering that request is the
only thing standing between a scripted fixture and a run that needs a human in a
TUI.

WHY THIS SHAPE, and not seeding credentials into the fixture home:

  The engine NEVER sees a refresh token. It asks for a bearer token, caches it,
  and asks again when the cache nears expiry. So the engine has no refresh
  authority at all. Seeding a copy of the credential DB into the fixture would
  create a SECOND refresh authority against an IAM Identity Center that rotates
  refresh tokens on use — whichever side refreshed second would get
  `invalid_grant`, and a fixture run could log out the operator's real session.
  Answering the callback instead means there is exactly one authority (the
  operator's normal Kiro usage), and the fixture home holds no credential at all
  — so an agent with shell access inside the fixture has nothing to read.

WHAT IT DELIBERATELY DOES NOT DO: refresh. If the token is too close to expiry,
this fails LOUDLY before starting rather than attempting an OIDC refresh. That
is the whole reason the rotation hazard above stays theoretical. Operator
ruling: "you dont need to handle refreshing, just fail loud."

The contract, read out of `AcpCallbackAuthProvider`:

  request  : `_kiro/auth/getAccessToken` with params `{}` (the host gets no input)
  response : accessToken  REQUIRED, falsy -> TokenInvalidError
             expiresAt    REQUIRED, must parse AND be more than REFRESH_BUFFER_MS
                          (3 minutes) in the future, else TokenInvalidError
             profileArn   optional; segment 4 gives the region, absent -> us-east-1

The token is read in-process from the operator's credential store and is NEVER
printed, logged, or placed in a transcript. Only its LENGTH and EXPIRY are ever
emitted. Nothing here reads the refresh token.
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import queue
import time
from datetime import datetime, timezone

# The engine rejects a token inside this window, so the host must too — earlier
# and with a better message.
REFRESH_BUFFER_SEC = 3 * 60
# Refuse to start a run that cannot plausibly finish inside the token's life.
# Not a guess at run length: it is the margin below which the engine's own
# buffer would trip mid-run instead of at startup, where it is diagnosable.
MIN_HEADROOM_SEC = 5 * 60

TOKEN_KEY = "kirocli:odic:token"
# The profile ARN lives in a DIFFERENT table from the token, and it is NOT
# optional in practice. The engine treats `profileArn` as optional — it only
# uses it to derive a region, falling back to us-east-1. But the Kiro Runtime
# Service REJECTS a request without it:
#
#   profileArn is required for this request. (GenericValidationError)
#
# That error arrives AFTER a successful auth handshake, so it reads as an auth
# failure and is not one. Supplying the ARN is what turns a valid token into a
# usable one.
PROFILE_KEY = "api.codewhisperer.profile"


def credential_db() -> str:
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(xdg, "kiro-cli", "data.sqlite3")


def read_token():
    """Return (access_token, expires_at_iso, remaining_seconds).

    Reads ONLY the two fields the callback contract needs. The refresh token
    lives in the same row and is deliberately not extracted.
    """
    db = credential_db()
    if not os.path.exists(db):
        raise SystemExit(f"no credential store at {db} — is this machine logged in?")
    # Read-only URI: this process must never be the reason the store changes.
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = con.execute("select value from auth_kv where key = ?", (TOKEN_KEY,)).fetchone()
    finally:
        con.close()
    if not row:
        raise SystemExit(f"no {TOKEN_KEY} row — run `kiro-cli login` once on this machine")

    blob = json.loads(row[0])
    token = blob.get("access_token")
    expires_at = blob.get("expires_at")
    if not token or not expires_at:
        raise SystemExit("credential row is missing access_token or expires_at")

    # Trim fractional seconds; the engine parses ISO-8601 and so does this.
    iso = expires_at.replace("Z", "+00:00")
    if "." in iso:
        head, rest = iso.split(".", 1)
        offset = rest[rest.find("+"):] if "+" in rest else ""
        iso = head + offset
    remaining = int((datetime.fromisoformat(iso) - datetime.now(timezone.utc)).total_seconds())
    return token, expires_at, remaining


def read_profile_arn():
    """The CodeWhisperer profile ARN, from the `state` table.

    Returns None rather than raising: the engine tolerates its absence (region
    falls back to us-east-1) and the resulting service error is explicit about
    what is missing, which is a better failure than a guess here.
    """
    db = credential_db()
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = con.execute("select value from state where key = ?", (PROFILE_KEY,)).fetchone()
    finally:
        con.close()
    if not row:
        return None
    try:
        return json.loads(row[0]).get("arn")
    except (json.JSONDecodeError, AttributeError):
        return None


def resolve_kiro() -> str:
    """The launcher injects flags the `acp` subcommand rejects, so resolve the
    real binary out of its exec line rather than invoking the wrapper.

    Both failure paths below are diagnosed rather than left to raise: this runs
    before anything else, and a TypeError from `realpath(None)` or a
    UnicodeDecodeError from reading an ELF file are both a long way from
    "kiro-cli is not where I expected".
    """
    found = shutil.which("kiro-cli")
    if found is None:
        raise SystemExit("kiro-cli is not on PATH — this harness drives the real CLI")
    launcher = os.path.realpath(found)
    try:
        with open(launcher, encoding="utf-8") as fh:
            head = fh.read(4096)
    except (OSError, UnicodeDecodeError):
        # Not a text wrapper: almost certainly the real compiled binary, which
        # is exactly what this function is trying to find.
        return launcher
    if not head.startswith("#!"):
        return launcher
    for line in head.splitlines():
        if line.startswith("exec ") and "/bin/kiro-cli" in line:
            for tok in line.split():
                # Unquote before matching. This launcher writes the store path
                # bare, but a generator change to a shell-escaped form is one
                # `escapeShellArg` away, and `endswith` would then silently stop
                # matching and fall through to the refusal below.
                tok = tok.strip("'\"")
                if tok.endswith("/bin/kiro-cli"):
                    return tok
    raise SystemExit(f"could not resolve the unwrapped kiro-cli from {launcher}")


class AcpHost:
    def __init__(self, scratch_home: str, workspace: str, token: str, expires_at: str,
                 profile_arn: str | None = None):
        self._token = token           # never printed
        self._expires_at = expires_at
        self._profile_arn = profile_arn
        self.workspace = workspace
        self.auth_calls = 0
        self.log = []

        env = dict(os.environ)
        env["HOME"] = scratch_home
        env["KIRO_LOG_LEVEL"] = "debug"
        # XDG_DATA_HOME deliberately NOT redirected: it holds the engine bundle
        # and the credential store, and an empty one forces a browser login.

        self.proc = subprocess.Popen(
            [resolve_kiro(), "acp", "--agent-engine", "v3"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, bufsize=1,
        )
        self.inbox: "queue.Queue" = queue.Queue()
        self.errors = []
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()
        self._next_id = 0

    def _pump_out(self):
        for line in self.proc.stdout:
            if line.strip():
                self.inbox.put(line.rstrip("\n"))
        self.inbox.put(None)

    def _pump_err(self):
        for line in self.proc.stderr:
            self.errors.append(line.rstrip("\n"))

    def _send(self, obj):
        try:
            self.proc.stdin.write(json.dumps(obj) + "\n")
            self.proc.stdin.flush()
            return True
        except (BrokenPipeError, ValueError):
            return False

    def call(self, method, params, timeout=120):
        self._next_id += 1
        rid = self._next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self._await(rid, timeout)

    def _await(self, target_id, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = self.inbox.get(timeout=max(0.5, deadline - time.time()))
            except queue.Empty:
                break
            if line is None:
                return {"__eof__": True, "exit": self.proc.poll()}
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            # A request FROM the agent.
            if "method" in msg and "id" in msg:
                self._handle_request(msg)
                continue
            # A notification: record its method for progress, drop the payload.
            if "method" in msg:
                self.log.append(msg["method"])
                continue
            if msg.get("id") == target_id:
                return msg
        return {"__timeout__": True, "exit": self.proc.poll()}

    def _handle_request(self, msg):
        method = msg["method"]
        if method == "_kiro/auth/getAccessToken":
            self.auth_calls += 1
            # NO REFRESH, by design. A second call means the engine is nearing
            # expiry; if the cached token can no longer satisfy the engine's own
            # buffer, say so loudly instead of quietly handing back a stale one.
            _, _, remaining = read_token()
            if remaining <= REFRESH_BUFFER_SEC:
                self._send({"jsonrpc": "2.0", "id": msg["id"], "error": {
                    "code": -32000,
                    "message": (f"token has {remaining}s left, inside the engine's "
                                f"{REFRESH_BUFFER_SEC}s refresh buffer; this host does not "
                                "refresh by design — use Kiro normally to renew, then re-run"),
                }})
                return
            result = {"accessToken": self._token, "expiresAt": self._expires_at}
            if self._profile_arn:
                result["profileArn"] = self._profile_arn
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
            return
        # Anything else the host does not implement, answered rather than left
        # hanging — an unanswered request blocks the engine.
        self._send({"jsonrpc": "2.0", "id": msg["id"],
                    "error": {"code": -32601, "message": f"host does not implement {method}"}})

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: acp-host.py <scratch-home> <workspace> [prompt]")
    scratch_home, workspace = sys.argv[1], sys.argv[2]
    prompt = sys.argv[3] if len(sys.argv) > 3 else "Reply with exactly: AUTH-OK"

    token, expires_at, remaining = read_token()
    print(f"token: {len(token)} chars, expires {expires_at}, {remaining}s remaining")
    if remaining <= REFRESH_BUFFER_SEC + MIN_HEADROOM_SEC:
        raise SystemExit(
            f"REFUSING: {remaining}s left, under the {REFRESH_BUFFER_SEC}s engine buffer plus "
            f"{MIN_HEADROOM_SEC}s headroom. This host does not refresh by design. Use Kiro "
            "normally to renew the token, then re-run."
        )

    profile_arn = read_profile_arn()
    if not profile_arn:
        print("WARNING: no profile ARN found; the service will reject prompts with "
              "'profileArn is required for this request'")
    else:
        # Identifier, not a credential — but the account segment is masked anyway.
        print("profileArn: " + re.sub(r":\d{12}:", ":<account>:", profile_arn))

    host = AcpHost(scratch_home, workspace, token, expires_at, profile_arn)
    out = {}
    try:
        init = host.call("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        })
        out["initialize_ok"] = "result" in init

        new = host.call("session/new", {"cwd": workspace, "mcpServers": []})
        out["session_new"] = "result" in new
        sid = (new.get("result") or {}).get("sessionId")
        out["sessionId_present"] = bool(sid)

        if sid:
            res = host.call("session/prompt", {
                "sessionId": sid,
                "prompt": [{"type": "text", "text": prompt}],
            }, timeout=180)
            out["prompt_ok"] = "result" in res
            out["prompt_result"] = res.get("result") or res.get("error")

        out["auth_callbacks_answered"] = host.auth_calls
    finally:
        host.close()

    print(json.dumps(out, indent=2, default=str)[:3000])
    if host.errors:
        print("--- stderr tail ---")
        print("\n".join(host.errors[-6:])[:1200])


if __name__ == "__main__":
    main()

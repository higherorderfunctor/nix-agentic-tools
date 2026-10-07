#!/usr/bin/env python3
"""Create an offline-only Kiro HOME from scratch; never read a credential store.

The auth_kv/state table layout is from SQLite .schema only. The token key and
access_token/expires_at fields are also named by fixtures/kiro-primitives/
harness/acp-host.py; BuilderIdToken fields are in the pinned native binary's
strings (crates/chat-cli-v2/src/auth/builder_id.rs). No real row is needed.

Baseline preconditions: workflows are not enabled or unlocked here, and no
agent engine or default agent is selected. Each case's launch flags select its
engine; SETTINGS and CASE_ENV explicitly supply workflow gates when required.
wire2.sh installs home-overlay's custom agent (tools: ["*"]) and the case's
agent overlay (gate's preToolUse hook for h3-hookblock). codex-side/offline.py
installs only the agents declared in its case JSON. No host settings or agents
are inherited. The h3 permission probes reproduced on unpatched 2.27.1 with
this baseline: workflows and extra agents are not prerequisites. On 2.28.0 the
same headless launches offer invoke_sub_agent instead of orchestrate_subagent;
that is a versioned observation, not a missing workflow fixture.
"""

import argparse
import json
import sqlite3
from pathlib import Path

ENDPOINT = "http://127.0.0.1:18765"
SERVICES = ("codewhisperer", "cps", "krs", "q")


def service_settings():
    """The single endpoint table for both offline runners."""
    return {
        f"api.{service}.service": {"endpoint": ENDPOINT, "region": "us-east-1"}
        for service in SERVICES
    }


def create_home(home):
    """Create a new fixture store, refusing to overwrite an existing database."""
    home = Path(home).resolve()
    data = home / ".local/share/kiro-cli"
    data.mkdir(parents=True, exist_ok=True)
    db = data / "data.sqlite3"
    # Exclusive creation prevents overwriting an operator-supplied login.
    with db.open("xb"):
        pass
    with sqlite3.connect(db) as con:
        con.executescript("""
            CREATE TABLE migrations (
                id INTEGER PRIMARY KEY, version INTEGER NOT NULL,
                migration_time INTEGER NOT NULL
            );
            CREATE TABLE history (
                id INTEGER PRIMARY KEY, command TEXT, shell TEXT, pid INTEGER,
                session_id TEXT, cwd TEXT, start_time INTEGER, hostname TEXT,
                exit_code INTEGER, end_time INTEGER, duration INTEGER
            );
            CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE state (key TEXT PRIMARY KEY, value BLOB);
            CREATE TABLE conversations (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE conversations_v2 (
                key TEXT NOT NULL, conversation_id TEXT NOT NULL,
                value TEXT NOT NULL, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, PRIMARY KEY (key, conversation_id)
            );
            CREATE INDEX idx_conversations_v2_key_updated
                ON conversations_v2(key, updated_at DESC);
            CREATE INDEX idx_conversations_v2_updated_at
                ON conversations_v2(updated_at DESC);
            CREATE TABLE extracted_kas_versions (
                version TEXT PRIMARY KEY, last_used_at INTEGER NOT NULL
            );
            CREATE TABLE pinned_bin_versions (
                version TEXT PRIMARY KEY, last_used_at INTEGER NOT NULL
            );
        """)
        # Native strings name migrations 000 through 010. Mark this schema
        # current so Kiro does not recreate tables (no real migration rows read).
        con.executemany("INSERT INTO migrations (version, migration_time) VALUES (?, 0)",
                        ((version,) for version in range(11)))
        con.execute("INSERT INTO auth_kv VALUES (?, ?)", (
            "kirocli:odic:token", json.dumps({
                "access_token": "FAKE_OFFLINE_PROBE_TOKEN",
                "expires_at": "2099-01-01T00:00:00Z",
                "oauth_flow": "DeviceCode",
                "region": "us-east-1",
                "start_url": ENDPOINT,
            }),
        ))
        # The native KAS auth callback resolves this profile before returning
        # the token. Native AuthProfile strings name profile_name; acp-host.py
        # names the state key and arn. Despite BLOB affinity, Kiro reads TEXT.
        con.execute("INSERT INTO state VALUES (?, ?)", (
            "api.codewhisperer.profile", json.dumps({
                "arn": "arn:aws:codewhisperer:us-east-1:000000000000:profile/FAKE_OFFLINE_PROBE",
                "profile_name": "offline",
            }),
        ))
    settings = home / ".kiro/settings"
    settings.mkdir(parents=True, exist_ok=True)
    (settings / "cli.json").write_text(json.dumps(service_settings()))
    db.chmod(0o600)
    return home


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("home", type=Path)
    print(create_home(parser.parse_args().home))


if __name__ == "__main__":
    main()

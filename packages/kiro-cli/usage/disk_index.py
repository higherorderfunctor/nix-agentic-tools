"""Incrementally index usage facts, never transcript text, from an explicit tree.

Only sessions linked to captures are indexed: a captured conversation or root
ID, or a session.json naming an indexed session through LINKS. Unlinked
sessions whose session.json and messages.jsonl both predate the earliest
capture are skipped unread; Kiro rewrites session.json on resume. A full pass
prunes disk rows for sessions no longer in scope.

JSONL files are assumed append-only between scans. Replacement, truncation,
same-size edits and edits to checkpoint/head bytes invalidate their old facts.
A middle-only edit followed by an append cannot be detected without rereading
the historical file; remove this source's disk_sources row to force a rescan.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys

from capture import decoded_json, open_database


DRAIN_CHUNK = 64 * 1024
IDENTIFIERS = ("executionId", "parentExecutionId", "parentSessionId", "rootExecutionId",
               "rootSessionId", "sessionId", "subExecutionId", "turnId")
LINKS = ("ownerSessionId", "parentSessionId", "rootConversationId", "rootSessionId")
# Coarse kernel file timestamps can trail the invocation's clock reading.
MTIME_SLACK_NS = 1_000_000_000
MAX_RECORD = 64 * 1024 * 1024
MAX_SESSION_METADATA = 4 * 1024 * 1024
SCHEMA = """
CREATE TABLE IF NOT EXISTS disk_session_omissions (
    session_path TEXT PRIMARY KEY, reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS disk_sessions (
    path TEXT PRIMARY KEY, model_id TEXT, model_scope TEXT NOT NULL,
    created_at TEXT, last_modified_at TEXT, numeric_metadata_json TEXT NOT NULL,
    file_identity TEXT NOT NULL, identifiers_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS disk_sources (
    path TEXT PRIMARY KEY, session_path TEXT NOT NULL, device INTEGER,
    inode INTEGER, size INTEGER, mtime_ns INTEGER, offset INTEGER,
    head_hash TEXT, checkpoint_hash TEXT
);
CREATE TABLE IF NOT EXISTS disk_omissions (
    source_path TEXT NOT NULL REFERENCES disk_sources(path) ON DELETE CASCADE,
    byte_offset INTEGER NOT NULL, byte_count INTEGER NOT NULL, reason TEXT NOT NULL,
    PRIMARY KEY(source_path, byte_offset)
);
CREATE TABLE IF NOT EXISTS disk_records (
    source_path TEXT NOT NULL REFERENCES disk_sources(path) ON DELETE CASCADE,
    byte_offset INTEGER NOT NULL, kind TEXT NOT NULL, timestamp TEXT,
    execution_id TEXT, turn_id TEXT, context_percentage REAL,
    elapsed_ms REAL, status TEXT, usage_json TEXT, identifiers_json TEXT NOT NULL,
    PRIMARY KEY(source_path, byte_offset)
);
CREATE TABLE IF NOT EXISTS disk_request_ids (
    source_path TEXT NOT NULL, byte_offset INTEGER NOT NULL,
    request_index INTEGER NOT NULL, request_id TEXT NOT NULL,
    PRIMARY KEY(source_path, byte_offset, request_index),
    FOREIGN KEY(source_path, byte_offset)
        REFERENCES disk_records(source_path, byte_offset) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS disk_request_id_lookup ON disk_request_ids(request_id);
"""


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def string(value):
    return value if isinstance(value, str) else None


def identifiers(*objects, keys=IDENTIFIERS):
    return {key: obj[key] for obj in objects for key in keys if isinstance(obj.get(key), str)}


def session_identifiers(session):
    """Top-level lineage plus _meta.kiro.serverSession/workflow step identity."""
    meta = session.get("_meta")
    kiro = meta.get("kiro") if isinstance(meta, dict) else None
    nested = [kiro.get(key) for key in ("serverSession", "workflow")] if isinstance(kiro, dict) else []
    # Reversed so a top-level key is never replaced by a nested one of the same name.
    return identifiers(*(obj for obj in reversed(nested) if isinstance(obj, dict)), session,
                       keys=(*IDENTIFIERS, *LINKS, "nodeId", "role", "workflowId"))


def session_id(value):
    return value if value.startswith("sess_") else "sess_" + value


def decode(data, path, offset):
    try:
        value = decoded_json(data)
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, UnicodeError, RecursionError):
        # JSON's error text may include transcript excerpts. Never echo it.
        raise ValueError(f"invalid JSON object: {path} at byte {offset}") from None


def fingerprints(stream, offset):
    stream.seek(0)
    head = hashlib.sha256(stream.read(min(offset, 4096))).hexdigest()
    stream.seek(max(0, offset - 4096))
    checkpoint = hashlib.sha256(stream.read(min(offset, 4096))).hexdigest()
    return head, checkpoint


def record_facts(source, offset, record):
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return
    kind = payload.get("type")
    context = None
    elapsed = None
    status = None
    usage = None
    request_ids = []
    if kind == "usage_summary":
        summaries = payload.get("promptTurnSummaries", [])
        if not isinstance(summaries, list):
            raise ValueError(f"invalid usage summaries: {source} at byte {offset}")
        # Only usage and its unit survive; tools, prompts and responses do not.
        usage = json.dumps([
            {"usage": number(item.get("usage")), "unit": string(item.get("unit"))}
            for item in summaries if isinstance(item, dict)
        ], allow_nan=False)
        elapsed = number(payload.get("elapsedTime"))
        status = string(payload.get("status"))
        request_ids = payload.get("requestIds", [])
        if not isinstance(request_ids, list) or any(
            not isinstance(item, str) for item in request_ids
        ):
            raise ValueError(f"invalid request IDs: {source} at byte {offset}")
    elif kind == "session_metadata" and payload.get("key") == "contextUsage":
        value = payload.get("value")
        context = number(value.get("usagePercentage")) if isinstance(value, dict) else None
        kind = "contextUsage"
    else:
        return
    return ((source, offset, kind, string(record.get("timestamp")),
             string(payload.get("executionId", record.get("executionId"))),
             string(payload.get("turnId", record.get("turnId"))), context,
             elapsed, status, usage, json.dumps(identifiers(record, payload), sort_keys=True)),
            [(source, offset, index, request_id) for index, request_id in enumerate(request_ids)])


def read_record(stream):
    """Bound allocation, draining oversized lines without retaining their contents."""
    line = stream.readline(MAX_RECORD + 1)
    size = len(line)
    if size <= MAX_RECORD:
        return line, size, line.endswith(b"\n")
    complete = line.endswith(b"\n")
    del line
    while not complete:
        chunk = stream.readline(DRAIN_CHUNK)
        size += len(chunk)
        if not chunk:
            break
        complete = chunk.endswith(b"\n")
    return None, size, complete


def index_messages(db, path, session_path):
    source = str(path)
    prior = db.execute("SELECT * FROM disk_sources WHERE path=?", (source,)).fetchone()
    with path.open("rb") as stream:
        stat = os.fstat(stream.fileno())
        offset = (prior["offset"] or 0) if prior else 0
        reset = prior and (
            (prior["device"], prior["inode"]) != (stat.st_dev, stat.st_ino)
            or stat.st_size < prior["size"]
            or (stat.st_size == prior["size"] and stat.st_mtime_ns != prior["mtime_ns"])
            or fingerprints(stream, offset) != (prior["head_hash"], prior["checkpoint_hash"])
        )
        if (prior and not reset and offset == stat.st_size
                and stat.st_size == prior["size"] and stat.st_mtime_ns == prior["mtime_ns"]):
            return  # Fully indexed, unchanged sources need no write transaction.
        with db:
            db.execute("BEGIN IMMEDIATE")
            if reset:
                db.execute("DELETE FROM disk_sources WHERE path=?", (source,))
                offset = 0
            head, checkpoint = fingerprints(stream, offset)
            db.execute("INSERT OR IGNORE INTO disk_sources VALUES (?,?,?,?,?,?,?,?,?)",
                       (source, str(session_path), stat.st_dev, stat.st_ino, stat.st_size,
                        stat.st_mtime_ns, offset, head, checkpoint))
        while True:
            stream.seek(offset)
            batch, size = [], 0
            # Parse outside the write transaction; neither scan time nor file size holds the writer lock.
            while len(batch) < 128 and size < 256 * 1024:
                line, length, complete = read_record(stream)
                if not complete:
                    break  # An unfinished tail is retried, even when already oversized.
                facts, reason = None, None
                if line is None:
                    reason = "record_exceeds_parse_budget"
                elif not line.isspace():
                    try:
                        facts = record_facts(source, offset, decode(line, path, offset))
                    except MemoryError:
                        reason = "parse_memory_exhausted"
                    except (ValueError, UnicodeError, RecursionError, OverflowError):
                        reason = "invalid_json_or_usage_record"
                batch.append((offset, length, facts, reason))
                offset = stream.tell()
                size += length
            head, checkpoint = fingerprints(stream, offset)
            with db:
                db.execute("BEGIN IMMEDIATE")
                for position, length, facts, reason in batch:
                    if reason:
                        db.execute("INSERT INTO disk_omissions VALUES (?,?,?,?)",
                                   (source, position, length, reason))
                    elif facts:
                        db.execute("INSERT INTO disk_records VALUES (?,?,?,?,?,?,?,?,?,?,?)", facts[0])
                        db.executemany("INSERT INTO disk_request_ids VALUES (?,?,?,?)", facts[1])
                db.execute(
                    "UPDATE disk_sources SET device=?,inode=?,size=?,mtime_ns=?,offset=?,"
                    "head_hash=?,checkpoint_hash=? WHERE path=?",
                    (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, offset,
                     head, checkpoint, source),
                )
            if not batch:
                break


def read_session(path):
    """Return (identity, session, identifiers); lineage decides scope, so always parse."""
    with path.open("rb") as stream:
        stat = os.fstat(stream.fileno())
        identity = f"{stat.st_dev}:{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}"
        data = stream.read(MAX_SESSION_METADATA + 1)
    if len(data) > MAX_SESSION_METADATA:
        raise ValueError(f"session metadata exceeds {MAX_SESSION_METADATA} bytes: {path}")
    session = decode(data, path, 0)
    return identity, session, session_identifiers(session)


def index_session(db, path, identity, session, ids):
    ids = json.dumps(ids, sort_keys=True)
    # Comparing identifiers too refreshes rows written before a lineage key was indexed.
    if db.execute("SELECT 1 FROM disk_sessions WHERE path=? AND file_identity=? AND identifiers_json=?",
                  (str(path.parent), identity, ids)).fetchone():
        return
    numeric = {key: value for key, value in session.items() if number(value) is not None}
    with db:
        db.execute(
            "INSERT OR REPLACE INTO disk_sessions VALUES (?,?,?,?,?,?,?,?)",
            (str(path.parent), string(session.get("modelId")), "session-current",
             string(session.get("createdAt")), string(session.get("lastModifiedAt")),
             json.dumps(numeric, allow_nan=False, sort_keys=True), identity, ids),
        )


def captured_sessions(db):
    """Captured conversation and root IDs, and the earliest capture start."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='captures'").fetchone():
        return set(), None
    names = set()
    for row in db.execute("""SELECT json_extract(metadata_json,'$."kiro:conversation_id"'),
                             json_extract(metadata_json,'$."kiro:root_conversation_id"') FROM captures"""):
        names.update(session_id(value) for value in row if isinstance(value, str) and value)
    return names, db.execute("SELECT min(started_utc_ns) FROM captures").fetchone()[0]


def modified_ns(session):
    times = []
    for name in ("session.json", "messages.jsonl"):
        try:
            times.append(os.stat(session / name, follow_symlinks=False).st_mtime_ns)
        except FileNotFoundError:
            pass
    return max(times, default=None)


def prune(db, table, column, keep):
    stale = [(row[0],) for row in db.execute(f"SELECT DISTINCT {column} FROM {table}") if row[0] not in keep]
    if not stale:
        return
    # One set-based DELETE; per-row deletes made the first prune take seconds.
    with db:
        db.execute("CREATE TEMP TABLE IF NOT EXISTS stale_paths(path TEXT PRIMARY KEY)")
        db.execute("DELETE FROM stale_paths")
        db.executemany("INSERT INTO stale_paths VALUES (?)", stale)
        db.execute(f"DELETE FROM {table} WHERE {column} IN (SELECT path FROM stale_paths)")


def index_tree(db, sessions, since=None):
    """Scan exactly <root>/<workspace>/sess_*; no home-directory discovery.

    With since (UTC ns), only sessions modified since then are read and nothing
    is pruned; already indexed sessions still anchor their descendants.
    """
    sessions = Path(sessions).resolve(strict=True)
    if not sessions.is_dir():
        raise ValueError("--sessions must be a directory")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(SCHEMA)
    metadata_omissions = {row[0] for row in db.execute("SELECT session_path FROM disk_session_omissions")}
    scope, earliest = captured_sessions(db)
    if since is not None:
        scope |= {Path(row[0]).name for row in db.execute("SELECT path FROM disk_sessions")}
    cutoff = since - MTIME_SLACK_NS if since is not None else earliest
    candidates = {}
    # Sub-execution logs have no usage records in the observed format.
    for workspace in sessions.iterdir() if scope else ():
        if workspace.is_symlink() or not workspace.is_dir():
            continue
        for session in workspace.iterdir():
            if session.is_symlink() or not session.is_dir() or not session.name.startswith("sess_"):
                continue
            if since is not None or session.name not in scope:
                modified = modified_ns(session)
                if modified is None or cutoff is None or modified < cutoff:
                    continue
            metadata = session / "session.json"
            facts = None
            if metadata.is_file() and not metadata.is_symlink():
                try:
                    facts = read_session(metadata)
                except (OSError, ValueError) as error:
                    facts = "unreadable_session_metadata" if isinstance(error, OSError) else "invalid_session_metadata"
            candidates[session] = facts
    growing = True
    while growing:
        growing = False
        for session, facts in candidates.items():
            if session.name not in scope and isinstance(facts, tuple) and any(
                    isinstance(facts[2].get(key), str) and session_id(facts[2][key]) in scope for key in LINKS):
                scope.add(session.name)
                growing = True
    indexed = [session for session in candidates if session.name in scope]
    for session, facts in candidates.items():
        if isinstance(facts, str):
            # Unknown ancestry stays visible even when its messages are out of scope.
            with db:
                db.execute("DELETE FROM disk_sessions WHERE path=?", (str(session),))
                db.execute("INSERT OR REPLACE INTO disk_session_omissions VALUES (?,?)", (str(session), facts))
        elif facts:
            if session.name in scope:
                index_session(db, session / "session.json", *facts)
            if str(session) in metadata_omissions:
                with db:
                    db.execute("DELETE FROM disk_session_omissions WHERE session_path=?", (str(session),))
    for session in indexed:
        messages = session / "messages.jsonl"
        if messages.is_file() and not messages.is_symlink():
            index_messages(db, messages, session)
    if since is None:
        keep = {str(session) for session in indexed}
        prune(db, "disk_sessions", "path", keep)
        prune(db, "disk_sources", "session_path", keep)
        prune(db, "disk_session_omissions", "session_path",
              {str(session) for session, facts in candidates.items() if isinstance(facts, str)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--sessions", type=Path, required=True)
    parser.add_argument("--json", action="store_true", help="write index counts as JSON")
    args = parser.parse_args()
    try:
        with open_database(args.db) as db:
            index_tree(db, args.sessions)
            if db.execute("PRAGMA freelist_count").fetchone()[0]:
                # Pruned pages only leave the file after VACUUM and a WAL checkpoint.
                db.execute("VACUUM")
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            sources = db.execute("SELECT count(*) FROM disk_sources").fetchone()[0]
            records = db.execute("SELECT count(*) FROM disk_records").fetchone()[0]
            omitted = db.execute("SELECT (SELECT count(*) FROM disk_omissions) + (SELECT count(*) FROM disk_session_omissions)").fetchone()[0]
            if args.json:
                print(json.dumps({"omitted_records": omitted, "records": records, "sources": sources}, sort_keys=True))
            else:
                print(f"Index contains {sources} sources, {records} usage/context records, {omitted} omitted records.")
            if omitted:
                print("Warning: omitted records or session metadata have unknown usage coverage or lineage; totals and descendant discovery may be incomplete.", file=sys.stderr)
        db.close()
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()

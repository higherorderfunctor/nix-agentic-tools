"""Incrementally index usage facts, never transcript text, from an explicit tree.

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

from capture import decoded_json, open_database


MAX_RECORD = 4 * 1024 * 1024
IDENTIFIERS = ("executionId", "parentExecutionId", "parentSessionId", "rootExecutionId",
               "rootSessionId", "sessionId", "subExecutionId", "turnId")
SCHEMA = """
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


def identifiers(*objects):
    return json.dumps({key: obj[key] for obj in objects for key in IDENTIFIERS
                       if isinstance(obj.get(key), str)}, sort_keys=True)


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


def import_record(db, source, offset, record):
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
    db.execute(
        "INSERT INTO disk_records VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (source, offset, kind, string(record.get("timestamp")),
         string(payload.get("executionId", record.get("executionId"))),
         string(payload.get("turnId", record.get("turnId"))), context,
         elapsed, status, usage, identifiers(record, payload)),
    )
    db.executemany(
        "INSERT INTO disk_request_ids VALUES (?,?,?,?)",
        ((source, offset, index, request_id) for index, request_id in enumerate(request_ids)),
    )


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
                line = stream.readline(MAX_RECORD + 1)
                if len(line) > MAX_RECORD:
                    raise ValueError(f"record exceeds {MAX_RECORD} bytes: {source} at byte {offset}")
                if not line or not line.endswith(b"\n"):
                    break
                batch.append((offset, decode(line, path, offset)))
                offset = stream.tell()
                size += len(line)
            head, checkpoint = fingerprints(stream, offset)
            with db:
                db.execute("BEGIN IMMEDIATE")
                for position, record in batch:
                    import_record(db, source, position, record)
                db.execute(
                    "UPDATE disk_sources SET device=?,inode=?,size=?,mtime_ns=?,offset=?,"
                    "head_hash=?,checkpoint_hash=? WHERE path=?",
                    (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, offset,
                     head, checkpoint, source),
                )
            if not batch:
                break


def index_session(db, path):
    with path.open("rb") as stream:
        stat = os.fstat(stream.fileno())
        identity = f"{stat.st_dev}:{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}"
        prior = db.execute("SELECT file_identity FROM disk_sessions WHERE path=?", (str(path.parent),)).fetchone()
        if prior and prior[0] == identity:
            return
        data = stream.read(MAX_RECORD + 1)
    if len(data) > MAX_RECORD:
        raise ValueError(f"session metadata exceeds {MAX_RECORD} bytes: {path}")
    session = decode(data, path, 0)
    numeric = {key: value for key, value in session.items() if number(value) is not None}
    with db:
        db.execute(
            "INSERT OR REPLACE INTO disk_sessions VALUES (?,?,?,?,?,?,?,?)",
            (str(path.parent), string(session.get("modelId")), "session-current",
             string(session.get("createdAt")), string(session.get("lastModifiedAt")),
             json.dumps(numeric, allow_nan=False, sort_keys=True), identity, identifiers(session)),
        )


def index_tree(db, sessions):
    """Scan exactly <root>/<workspace>/sess_*; no home-directory discovery."""
    sessions = Path(sessions).resolve(strict=True)
    if not sessions.is_dir():
        raise ValueError("--sessions must be a directory")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(SCHEMA)
    # Sub-execution logs have no usage records in the observed format.
    for workspace in sessions.iterdir():
        if workspace.is_symlink() or not workspace.is_dir():
            continue
        for session in workspace.iterdir():
            if session.is_symlink() or not session.is_dir() or not session.name.startswith("sess_"):
                continue
            metadata = session / "session.json"
            messages = session / "messages.jsonl"
            if metadata.is_file() and not metadata.is_symlink():
                index_session(db, metadata)
            if messages.is_file() and not messages.is_symlink():
                index_messages(db, messages, session)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--sessions", type=Path, required=True)
    args = parser.parse_args()
    try:
        with open_database(args.db) as db:
            index_tree(db, args.sessions)
        db.close()
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()

"""Incrementally index Kiro session usage facts from a session tree.

The explicit index scans for sessions linked to any capture and prunes rows
that fall out of scope. It skips unlinked sessions if both files predate the
earliest capture.

The exit refresh starts with queued launches' captured conversation and root
IDs and explicit resume IDs. It indexes changed sessions in that lineage and
leaves pruning to the explicit index.

JSONL files are assumed append-only between scans. Replacement, truncation,
same-size edits and edits to checkpoint/head bytes invalidate their old facts.
A middle-only edit followed by an append cannot be detected without rereading
the historical file; remove this source's disk_sources row to force a rescan.
"""

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import sys
from typing import NamedTuple

from capture import compact, decoded_json, lock_beside, open_database


CAPTURE_SESSION_IDS = """json_extract(metadata_json,'$."kiro:conversation_id"'),
                         json_extract(metadata_json,'$."kiro:root_conversation_id"')"""
DRAIN_CHUNK = 64 * 1024
# The full pass waits on it; runtime.refresh_disk_index skips while it is held.
INDEX_LOCK = ".index.lock"
REFRESH_LOCK = ".refresh.lock"  # Exit refreshes queue here; index_messages reads its offset before the write transaction.
IDENTIFIERS = ("executionId", "parentExecutionId", "parentSessionId", "rootExecutionId",
               "rootSessionId", "sessionId", "subExecutionId", "turnId")
LINKS = ("ownerSessionId", "parentSessionId", "rootConversationId", "rootSessionId")
LINK_EXPRESSIONS = {key: f"json_extract(identifiers_json,'$.{key}')" for key in LINKS}
LINK_INDEXES = "\n".join(
    f"CREATE INDEX IF NOT EXISTS disk_sessions_{key} ON disk_sessions({expression}) "
    f"WHERE {expression} IS NOT NULL;"
    for key, expression in LINK_EXPRESSIONS.items()
)
# Coarse kernel file timestamps can trail the invocation's clock reading.
MTIME_SLACK_NS = 1_000_000_000
MAX_RECORD = 64 * 1024 * 1024
MAX_SESSION_METADATA = 4 * 1024 * 1024
PENDING_SCHEMA = """
CREATE TABLE IF NOT EXISTS disk_refresh_pending (
    invocation TEXT PRIMARY KEY, since_ns INTEGER NOT NULL,
    resume_id TEXT, retry INTEGER NOT NULL DEFAULT 0
)
"""
SCHEMA = f"""
{PENDING_SCHEMA};
CREATE TABLE IF NOT EXISTS disk_session_omissions (
    session_path TEXT PRIMARY KEY, reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS disk_sessions (
    path TEXT PRIMARY KEY, model_id TEXT, model_scope TEXT NOT NULL,
    created_at TEXT, last_modified_at TEXT, numeric_metadata_json TEXT NOT NULL,
    file_identity TEXT NOT NULL, identifiers_json TEXT NOT NULL
);
{LINK_INDEXES}
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


def index_messages(db, path):
    """Stream transcript facts into bounded transactions with a resumable checkpoint."""
    source = str(path)
    prior = db.execute("SELECT * FROM disk_sources WHERE path=?", (source,)).fetchone()
    with path.open("rb") as stream:
        info = os.fstat(stream.fileno())
        identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        offset = (prior["offset"] or 0) if prior else 0
        reset = prior and (
            (prior["device"], prior["inode"]) != identity[:2]
            or info.st_size < prior["size"]
            or (info.st_size == prior["size"] and info.st_mtime_ns != prior["mtime_ns"])
            or fingerprints(stream, offset) != (prior["head_hash"], prior["checkpoint_hash"])
        )
        if (prior and not reset and offset == info.st_size
                and info.st_size == prior["size"] and info.st_mtime_ns == prior["mtime_ns"]):
            return
        if reset:
            offset = 0
        hashes = fingerprints(stream, offset)
        with db:
            db.execute("BEGIN IMMEDIATE")
            if reset:
                db.execute("DELETE FROM disk_sources WHERE path=?", (source,))
            db.execute("INSERT OR IGNORE INTO disk_sources VALUES (?,?,?,?,?,?,?,?,?)",
                       (source, str(path.parent), *identity, offset, *hashes))
        while True:
            stream.seek(offset)
            batch, size = [], 0
            # File reads stay outside the transaction so they cannot hold up capture writes.
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
            hashes = fingerprints(stream, offset)
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
                    (*identity, offset, *hashes, source),
                )
            if not batch:
                break


class SessionMetadata(NamedTuple):
    """Parsed session file facts for lineage and metadata indexing."""

    identity: str
    session: dict
    identifiers: dict


def read_session(path):
    """Parse session metadata so its identifiers can determine index scope."""
    with path.open("rb") as stream:
        stat = os.fstat(stream.fileno())
        identity = f"{stat.st_dev}:{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}"
        data = stream.read(MAX_SESSION_METADATA + 1)
    if len(data) > MAX_SESSION_METADATA:
        raise ValueError(f"session metadata exceeds {MAX_SESSION_METADATA} bytes: {path}")
    session = decode(data, path, 0)
    return SessionMetadata(identity, session, session_identifiers(session))


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


def capture_names(rows):
    """Normalize conversation and root IDs from either capture scope query."""
    return {session_id(value) for row in rows for value in row if isinstance(value, str) and value}


def captured_sessions(db):
    """Captured conversation and root IDs, and the earliest capture start."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='captures'").fetchone():
        return set(), None
    names = capture_names(db.execute(f"SELECT {CAPTURE_SESSION_IDS} FROM captures"))
    return names, db.execute("SELECT min(started_utc_ns) FROM captures").fetchone()[0]


def invocation_sessions(db, invocations):
    """Return the union of conversation and root names for the queued launches."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='captures'").fetchone():
        return set()
    query = f"SELECT {CAPTURE_SESSION_IDS} FROM captures WHERE json_extract(metadata_json,'$.invocation')=?"
    return capture_names(row for invocation in invocations for row in db.execute(query, (invocation,)))


def session_links(ids):
    """Return directory names referenced by parsed or previously indexed lineage."""
    return {session_id(value) for key in LINKS if isinstance(value := ids.get(key), str)}


def indexed_child_paths(db, name):
    """Find recorded children by the raw and prefixed forms of a session name."""
    raw = name.removeprefix("sess_")
    if raw.startswith("sess_"):
        raw = name
    return {Path(row[0]) for expression in LINK_EXPRESSIONS.values()
            for row in db.execute(f"SELECT path FROM disk_sessions WHERE {expression} IN (?,?)", (name, raw))}


def add_session_links(children, path, facts):
    """Add edges from readable session metadata to the lineage graph."""
    if isinstance(facts, SessionMetadata):
        for parent in session_links(facts.identifiers):
            children[parent].add(path.name)


def linked_sessions(captured, children):
    """Follow parsed and recorded lineage from the scoped session names."""
    scope = set(captured)
    pending = list(scope)
    while pending:
        new = children[pending.pop()] - scope
        scope.update(new)
        pending.extend(new)
    return scope


def entry_stat(path, mode_matches):
    """Return the lstat for a real entry of the expected type, if present."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return info if mode_matches(info.st_mode) else None


def warn_session_read(session):
    """Name the session without echoing an exception's possibly private details."""
    print(f"Warning: could not read Kiro session {session}; disk observations may be stale.", file=sys.stderr)


def warn_workspace_read(workspace):
    """Name the workspace without echoing an exception's possibly private details."""
    print(f"Warning: could not read Kiro workspace {workspace}; disk observations may be stale.", file=sys.stderr)


def exit_candidates(db, sessions, captured, cutoff):
    """Return changed session candidates and lineage from their files and the index."""
    candidates, children = {}, defaultdict(set)
    checked, workspaces = set(), set()

    def skip_unreadable_session(session):
        """Warn once and prevent discovery from probing this entry again."""
        checked.add(session)
        warn_session_read(session)

    def record_changed_session(session, listed=False):
        """Keep metadata, lineage and transcript presence for a changed session."""
        if session in checked:
            return
        checked.add(session)
        try:
            if not listed and entry_stat(session, stat.S_ISDIR) is None:
                return
            metadata_path, messages_path = session / "session.json", session / "messages.jsonl"
            metadata = entry_stat(metadata_path, stat.S_ISREG)
            transcript = entry_stat(messages_path, stat.S_ISREG)
            if not any(info and info.st_mtime_ns >= cutoff for info in (metadata, transcript)):
                return
            facts = metadata_facts(metadata_path) if metadata else None
        except OSError:
            warn_session_read(session)
            return
        candidates[session] = facts, transcript is not None
        add_session_links(children, session, facts)

    for workspace in sorted(directories(sessions, on_entry_error=warn_session_read)):
        try:
            info = entry_stat(workspace, stat.S_ISDIR)
        except OSError:
            warn_workspace_read(workspace)
            continue
        if info is None:
            continue
        workspaces.add(workspace)
        for name in sorted(captured):
            record_changed_session(workspace / name)
        if info.st_mtime_ns >= cutoff:
            try:
                for session in directories(workspace, "sess_", skip=checked, on_entry_error=skip_unreadable_session):
                    # Indexed paths are checked only when their recorded lineage leads back to this launch.
                    if not db.execute(
                        "SELECT 1 FROM disk_sessions WHERE path=?", (str(session),)
                    ).fetchone():
                        record_changed_session(session, listed=True)
            except OSError:
                # A workspace that cannot be listed must not stop the others; failing to list the session root still fails the pass.
                warn_workspace_read(workspace)

    pending, visited = sorted(captured), set(captured)
    while pending:
        parent = pending.pop()
        descendants = children[parent].copy()
        for session in sorted(indexed_child_paths(db, parent)):
            if session.parent not in workspaces:
                continue
            record_changed_session(session)
            descendants.add(session.name)
            if session not in candidates:
                children[parent].add(session.name)  # Fresh metadata supersedes recorded lineage.
        pending.extend(sorted(descendants - visited))
        visited.update(descendants)
    return candidates, children


def modified_ns(session):
    times = []
    for name in ("session.json", "messages.jsonl"):
        try:
            times.append(os.stat(session / name, follow_symlinks=False).st_mtime_ns)
        except FileNotFoundError:
            pass
    return max(times, default=None)


def prune(db, table, column, keep, root):
    """Delete rows under root that are not in keep and return how many; rows from other session roots stay."""
    prefix = str(root) + os.sep
    stale = [(row[0],) for row in db.execute(f"SELECT DISTINCT {column} FROM {table}")
             if row[0].startswith(prefix) and row[0] not in keep]
    if not stale:
        return 0
    # One set-based DELETE; per-row deletes made the first prune take seconds.
    with db:
        db.execute("CREATE TEMP TABLE IF NOT EXISTS stale_paths(path TEXT PRIMARY KEY)")
        db.execute("DELETE FROM stale_paths")
        db.executemany("INSERT INTO stale_paths VALUES (?)", stale)
        return db.execute(f"DELETE FROM {table} WHERE {column} IN (SELECT path FROM stale_paths)").rowcount


def directories(root, prefix="", *, skip=(), on_entry_error=None):
    """Yield matching directories and let exit refreshes skip failed type checks."""
    with os.scandir(root) as entries:
        for entry in entries:
            if not entry.name.startswith(prefix):
                continue
            path = Path(entry.path)
            if path in skip:
                continue
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                if on_entry_error is None:
                    raise
                on_entry_error(path)
                continue
            if is_dir:
                yield path


def metadata_facts(path, *, record_read_error=False):
    """Read lineage and metadata or return the reason they could not be parsed."""
    try:
        return read_session(path)
    except ValueError:
        return "invalid_session_metadata"
    except OSError:
        if not record_read_error:
            raise
        return "unreadable_session_metadata"


def update_metadata(db, session, facts, in_scope):
    """Store metadata and omissions, clearing the omission when metadata becomes readable."""
    if isinstance(facts, str):
        # Unknown ancestry stays visible even when its messages are out of scope.
        with db:
            db.execute("DELETE FROM disk_sessions WHERE path=?", (str(session),))
            db.execute("INSERT OR REPLACE INTO disk_session_omissions VALUES (?,?)", (str(session), facts))
    elif facts:
        if in_scope:
            index_session(db, session / "session.json", facts.identity, facts.session, facts.identifiers)
        if db.execute("SELECT 1 FROM disk_session_omissions WHERE session_path=?", (str(session),)).fetchone():
            with db:
                db.execute("DELETE FROM disk_session_omissions WHERE session_path=?", (str(session),))


def refresh_sessions(db, sessions, captured, cutoff):
    """Refresh changed candidates linked to the launch without pruning other rows."""
    candidates, children = exit_candidates(db, sessions, captured, cutoff)
    scope = linked_sessions(captured, children)
    for session, (facts, has_transcript) in candidates.items():
        in_scope = session.name in scope
        try:
            update_metadata(db, session, facts, in_scope)
            if in_scope and has_transcript:
                index_messages(db, session / "messages.jsonl")
        except OSError:
            # Earlier batches keep their checkpoint so the next pass resumes there.
            warn_session_read(session)


def index_tree(db, sessions, *, launch: tuple[tuple[str, ...], int] | None = None,
               resume_ids: tuple[str | None, ...] = ()):
    """Index <root>/<workspace>/sess_* and return the number of rows pruned.

    Runtime supplies queued invocation markers, their earliest UTC start in ns,
    and resume IDs to restrict discovery and skip pruning.
    """
    sessions = Path(sessions).resolve(strict=True)
    if not sessions.is_dir():
        raise ValueError("--sessions must be a directory")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript(SCHEMA)
    if launch is not None:
        invocations, since = launch
        captured = invocation_sessions(db, invocations) | capture_names((resume_ids,))
        captured = {name for name in captured if Path(name).name == name}
        if captured:
            refresh_sessions(db, sessions, captured, since - MTIME_SLACK_NS)
        return 0

    captured, cutoff = captured_sessions(db)
    candidates = {}
    children = defaultdict(set)
    for workspace in directories(sessions) if captured else ():
        # Sub-execution logs have no usage records in the observed format.
        for session in directories(workspace, "sess_"):
            if session.name not in captured:
                modified = modified_ns(session)
                if modified is None or cutoff is None or modified < cutoff:
                    continue
            metadata = session / "session.json"
            facts = metadata_facts(metadata, record_read_error=True) if metadata.is_file() and not metadata.is_symlink() else None
            candidates[session] = facts
            add_session_links(children, session, facts)
    scope = linked_sessions(captured, children)
    indexed = [session for session in candidates if session.name in scope]
    for session, facts in candidates.items():
        update_metadata(db, session, facts, session.name in scope)
    for session in indexed:
        messages = session / "messages.jsonl"
        if messages.is_file() and not messages.is_symlink():
            index_messages(db, messages)
    keep = {str(session) for session in indexed}
    return (prune(db, "disk_sessions", "path", keep, sessions)
            + prune(db, "disk_sources", "session_path", keep, sessions)
            + prune(db, "disk_session_omissions", "session_path",
                    {str(session) for session, facts in candidates.items() if isinstance(facts, str)}, sessions))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--sessions", type=Path, required=True)
    parser.add_argument("--json", action="store_true", help="write index counts as JSON")
    args = parser.parse_args()
    try:
        with open_database(args.db) as db:
            lock_beside(args.db, INDEX_LOCK, blocking=True)  # Held until this process exits.
            if index_tree(db, args.sessions):
                # Pruned pages only leave the file after VACUUM and a WAL checkpoint; pages
                # freed by anything else, such as sealing, are left for later captures to reuse.
                compact(db)
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

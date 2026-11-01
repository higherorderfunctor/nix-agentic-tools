"""Private, independent Kiro calibration evidence store; no provider calls."""

import argparse
import base64
from contextlib import contextmanager
import fcntl
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import sqlite3
import stat
import struct
import sys
import threading
import time
import uuid
import zlib

SCHEMA = """
CREATE TABLE IF NOT EXISTS capture_meta (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS captures (
 id TEXT PRIMARY KEY, started_utc_ns INTEGER, started_mono_ns INTEGER,
 ended_utc_ns INTEGER, ended_mono_ns INTEGER, metadata_json TEXT,
 request_gzip BLOB, request_sha256 TEXT, fingerprints_json TEXT,
 response_json TEXT, response_sha256 TEXT, summary_json TEXT,
 observed_chunks INTEGER, observed_bytes INTEGER, dropped_chunks INTEGER,
 dropped_bytes INTEGER, transport_ended INTEGER, completion_seen INTEGER,
 state TEXT, issues_json TEXT,
 credits REAL, context_usage_percentage REAL, input_tokens INTEGER,
 output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER
);
CREATE INDEX IF NOT EXISTS capture_session ON captures(json_extract(metadata_json, '$."kiro:conversation_id"'));
CREATE INDEX IF NOT EXISTS capture_request_id ON captures(json_extract(response_json, '$.upstream_request_id'));
CREATE TABLE IF NOT EXISTS chunks (
 capture_id TEXT, seq INTEGER, utc_ns INTEGER, mono_ns INTEGER,
 entity_gzip BLOB, application_gzip BLOB,
 PRIMARY KEY(capture_id, seq)
);
CREATE TABLE IF NOT EXISTS events (
 capture_id TEXT, seq INTEGER, chunk_seq INTEGER, utc_ns INTEGER,
 mono_ns INTEGER, event_name TEXT, frame_gzip BLOB, data_json TEXT,
 PRIMARY KEY(capture_id, seq)
);
CREATE TABLE IF NOT EXISTS sealed_requests (
 capture_id TEXT PRIMARY KEY,
 base_id TEXT, -- NULL: an independent frame; else the capture whose raw request is the prefix
 body_zstd BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS sealed_responses (
 capture_id TEXT PRIMARY KEY,
 transport_zstd BLOB NOT NULL,
 recipe_zstd BLOB NOT NULL,
 exceptions_zstd BLOB NOT NULL
);
-- A capture is sealed exactly when its capture_facts row exists: query.FACTS evaluated over its staged rows.
CREATE TABLE IF NOT EXISTS capture_facts (
 capture_id TEXT PRIMARY KEY,
 extra_chars INTEGER,
 retained INTEGER, terminal INTEGER, text_only INTEGER, no_reasoning_tools INTEGER
);
-- A capture created at version 2 stays here until its seal commits; each start seals what a stop or crash left.
CREATE TABLE IF NOT EXISTS pending_seals (capture_id TEXT PRIMARY KEY);
"""


@contextmanager
def snapshot(db):
    """One read transaction, so a capture committing on another connection cannot split a read; inside one, a no-op."""
    if db.in_transaction:
        yield
        return
    db.execute("BEGIN")
    try:
        yield
    finally:
        db.rollback()


def open_database(path):
    """Require a private directory; never change permissions on an existing path."""
    path = Path(path).expanduser().absolute()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    for candidate in (path.parent, path):
        if candidate.is_symlink():
            raise ValueError(f"refusing symlink: {candidate}")
        if candidate.exists():
            info = candidate.stat()
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError(f"private owner-only path required: {candidate}")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    db = sqlite3.connect(path, timeout=30)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        # WAL commits skip fsync; checkpoints still sync. A power loss can drop recent commits, never corrupt.
        db.execute("PRAGMA synchronous=NORMAL")
    except sqlite3.Error:
        db.close()
        raise
    db.row_factory = sqlite3.Row
    return db


def lock_beside(path, suffix, blocking=False, shared=False):
    """Owner-only flock on <db><suffix>, held until the returned fd closes; BlockingIOError when held and not blocking.

    shared: exit refreshes probe the index lock shared, so only an exclusive full index pass makes them skip."""
    fd = os.open(str(Path(path).expanduser().absolute()) + suffix, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | (0 if blocking else fcntl.LOCK_NB))
    except BaseException:
        os.close(fd)
        raise
    return fd


def compact(db):
    db.execute("VACUUM")
    # A reader's snapshot blocks the checkpoint without raising: its first column reads 1, and the WAL keeps its size.
    if db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]:
        raise sqlite3.OperationalError("wal checkpoint blocked by a reader")


def decoded_json(data):
    """Bound nesting consistently across Python JSON implementations."""
    value = json.loads(data)
    stack = [iter((value,))]
    while stack:
        child = next(stack[-1], StopIteration)
        if child is StopIteration:
            stack.pop()
        elif isinstance(child, str):
            child.encode("utf-8")  # Refuse lone JSON surrogates before extraction or SQLite writes.
        elif isinstance(child, (dict, list)):
            if len(stack) > 128:
                raise ValueError("JSON nesting limit")
            if isinstance(child, dict):
                for key in child:
                    key.encode("utf-8")
            stack.append(iter(child.values() if isinstance(child, dict) else child))
    return value


def packed(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def event_text(obj):
    return packed(obj) if obj is not None else None


def digest(value):
    return hashlib.sha256(value).hexdigest()


def child(value, *keys):
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def request_details(body, issues=None, rpc=False):
    """rpc: the addon selected the GenerateAssistantResponse x-amz-target; otherwise the body is CreateResponse."""
    hashes = {"prefixes": {str(n): digest(body[:n]) for n in (4096, 16384, 32768, 49152) if len(body) >= n}}
    metadata = {}
    if len(body) > 32 * 1024 * 1024:
        if issues is not None:
            issues.append("request_metadata_limit")
        return metadata, hashes
    try:
        obj = decoded_json(body)
        if not isinstance(obj, dict):
            return metadata, hashes
        if rpc:
            # AWS JSON 1.0 writes the whole input as the body; tools ride on the current message.
            message = child(obj, "conversationState", "currentMessage")
            fields = {"model": child(message, "userInputMessage", "modelId"),
                      "effort": child(obj, "additionalModelRequestFields", "output_config", "effort") or child(obj, "additionalModelRequestFields", "reasoning", "effort"),
                      "kiro:conversation_id": child(obj, "conversationState", "conversationId"),
                      "kiro:root_conversation_id": child(obj, "conversationState", "rootConversationId")}
            components = {key: value for key, value in (("currentMessage", message), ("history", child(obj, "conversationState", "history")), ("systemPrompt", obj.get("systemPrompt")),
                                                        ("tools", child(message, "userInputMessage", "userInputMessageContext", "tools"))) if value is not None}
            items, items_key = child(obj, "conversationState", "history"), "history_items"
        else:
            extra = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
            fields = {"model": obj.get("model"), "effort": child(obj, "reasoning", "effort"),
                      **{key: extra.get(key) for key in ("kiro:agent_continuation_id", "kiro:agent_id", "kiro:conversation_id", "kiro:execution_id", "kiro:parent_agent_id", "kiro:parent_execution_id", "kiro:parent_session_id", "kiro:root_conversation_id", "kiro:root_execution_id", "kiro:session_id")}}
            components = {key: obj[key] for key in ("input", "instructions", "reasoning", "tools") if key in obj}
            items, items_key = obj.get("input"), "input_items"
        metadata.update((key, value) for key, value in fields.items() if isinstance(value, str))
        for key, value in components.items():
            hashes[key] = digest(packed(value).encode())
        if isinstance(items, list):
            hashes[items_key] = [digest(packed(item).encode()) for item in items[:4096]]
            if len(items) > 4096 and issues is not None:
                issues.append("fingerprint_item_limit")
    except (ValueError, UnicodeError, RecursionError):
        if issues is not None:
            issues.append("invalid_request_json")
    return metadata, hashes


class SSE:
    """Incremental SSE framing, preserving exact frame bytes and UTF-8 boundaries."""

    LINE = re.compile(b"\r\n|\r|\n")

    def __init__(self, emit, limit=4 * 1024 * 1024):
        self.emit, self.limit = emit, limit
        self.buffer = b""
        self.frame = bytearray()
        self.lines = []
        self.disabled = False

    def feed(self, data, final=False):
        if self.disabled:
            return
        # Scan by offset and slice once: re-slicing per line made a chunk of blank lines quadratic.
        buffer, offset = self.buffer + data, 0
        while match := self.LINE.search(buffer, offset):
            if match.group() == b"\r" and match.end() == len(buffer) and not final:
                break
            self.frame += buffer[offset:match.end()]
            if match.start() > offset:
                self.lines.append(buffer[offset:match.start()])
            else:
                self.emit(bytes(self.frame), self.lines, False)
                self.frame.clear()
                self.lines = []
            offset = match.end()
            if len(self.frame) > self.limit:
                self.disabled = True
                self.buffer = b""
                return
        self.buffer = buffer[offset:]
        if len(self.frame) + len(self.buffer) > self.limit:
            self.disabled = True
            self.buffer = b""
        if final and not self.disabled and (self.frame or self.buffer):
            # EOF is not an SSE dispatch delimiter. Retain and flag the tail.
            self.frame.extend(self.buffer)
            self.emit(bytes(self.frame), self.lines + [self.buffer], True)
            self.buffer = b""
            self.frame.clear()


class EventStream:
    """Incremental application/vnd.amazon.eventstream framing; exact message bytes and both CRC32s are checked."""

    SIZES = {0: 0, 1: 0, 2: 1, 3: 2, 4: 4, 5: 8, 8: 8, 9: 16}  # fixed-width header value types

    def __init__(self, emit, limit=4 * 1024 * 1024):
        self.emit, self.limit = emit, limit
        self.buffer = bytearray()
        self.disabled = self.stopped = False

    def feed(self, data, final=False):
        if self.disabled or self.stopped:
            return
        buffer, offset = self.buffer, 0
        buffer += data
        while len(buffer) - offset >= 12:
            total, length, prelude = struct.unpack_from(">III", buffer, offset)
            crc = zlib.crc32(buffer[offset:offset + 8]) == prelude
            if not crc or total < 16 or length > total - 16:
                # An untrusted prelude leaves no next message boundary; raw chunks keep the rest.
                self.stopped = True
                self.emit(bytes(buffer[offset:offset + 12]), {}, None, "invalid_event_frame" if crc else "event_stream_crc")
                buffer.clear()
                return
            if total > self.limit:
                self.disabled = True
                buffer.clear()
                return
            if len(buffer) - offset < total:
                break
            frame = bytes(buffer[offset:offset + total])
            offset += total
            if zlib.crc32(frame[:-4]) != struct.unpack(">I", frame[-4:])[0]:
                self.emit(frame, {}, None, "event_stream_crc")
                continue
            try:
                headers = self.headers(frame[12:12 + length])
            except (IndexError, KeyError, ValueError, struct.error):
                self.emit(frame, {}, None, "invalid_event_frame")
                continue
            self.emit(frame, headers, frame[12 + length:-4], None)
        del buffer[:offset]
        if final and buffer:
            self.emit(bytes(buffer), {}, None, "unterminated_event")
            buffer.clear()

    @classmethod
    def headers(cls, raw):
        """String-typed headers only (:message-type, :event-type, ...); other types are skipped."""
        values, offset = {}, 0
        while offset < len(raw):
            size = raw[offset]
            name, kind = raw[offset + 1:offset + 1 + size].decode("utf-8"), raw[offset + 1 + size]
            offset += 2 + size
            if kind in (6, 7):
                (count,) = struct.unpack_from(">H", raw, offset)
                value, offset = raw[offset + 2:offset + 2 + count], offset + 2 + count
                if kind == 7:
                    values[name] = value.decode("utf-8")
            else:
                offset += cls.SIZES[kind]
        if offset != len(raw):
            raise ValueError("truncated event-stream header")
        return values


def terminal_extra(output):
    """Tool-argument and reasoning characters in one terminal response.output list, by kind."""
    counts = {"tool": 0, "reasoning": 0}
    for item in output:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "function_call" and isinstance(item.get("arguments"), str):
            counts["tool"] += len(item["arguments"])
        elif item.get("type") == "reasoning" and isinstance(item.get("content"), list):
            counts["reasoning"] += sum(len(part["text"]) for part in item["content"]
                                       if isinstance(part, dict) and part.get("type") == "reasoning_text" and isinstance(part.get("text"), str))
    return counts


def output_text(value):
    """Only final output_text parts; tool arguments/reasoning are separate evidence."""
    if isinstance(value, dict):
        if value.get("type") == "output_text" and isinstance(value.get("text"), str):
            yield value["text"]
        else:
            for key in ("content", "output"):
                yield from output_text(value.get(key))
    elif isinstance(value, list):
        for part in value:
            yield from output_text(part)


class CaptureCapacityError(RuntimeError):
    pass


DECODE_LIMIT = 16 * 1024 * 1024  # Decoded bytes one entity chunk may expand to.


def content_encoding(response):
    return response.get("content_encoding", "identity").lower().strip() or "identity"


def content_decoder(encoding):
    """The zlib decompressobj for gzip or deflate, else None; returned whole so EOF and trailing data stay readable."""
    if encoding in ("gzip", "deflate"):
        return zlib.decompressobj(16 + zlib.MAX_WBITS if encoding == "gzip" else zlib.MAX_WBITS)


def decode_chunk(decoder, data):
    """(application, ok) for one entity chunk; decoder None is identity.

    Corrupt input yields (None, False). Output past DECODE_LIMIT yields its partial output and False; the collector stores
    that partial chunk and decodes nothing after it."""
    if decoder is None:
        return data, len(data) <= DECODE_LIMIT
    try:
        application = decoder.decompress(data, DECODE_LIMIT + 1)
    except zlib.error:
        return None, False
    return application, len(application) <= DECODE_LIMIT and not decoder.unconsumed_tail


def framing_kind(response, rpc):
    if rpc:  # Kiro's client parses GenerateAssistantResponse as a binary event stream whatever its content type.
        return "eventstream"
    content_type = response.get("content_type", "")
    for media, key in (("text/event-stream", "sse"), ("application/vnd.amazon.eventstream", "eventstream")):
        if media in content_type:
            return key


# Synthetic 1 and 32 MiB requests: level 9 costs 1.8x level 6's CPU for 0.3% smaller BLOBs; level 1 is 3x
# faster but 16% larger, reaching the payload warning sooner. Small chunks compress alike at every level.
GZIP_LEVEL = 6
WARN_BYTES = 5 * 1024 ** 3  # Retained payload bytes past which the collector and exit summary warn.
# Payload copies the queue may refuse while parsing still sees every byte; usage stays complete without them.
OMISSIONS = {"request_payload_omitted", "response_payload_omitted"}
# Streamed /v1/responses tool-argument and reasoning parts; a kind with any of these ignores its terminal copy.
EXTRA_DELTAS = {"response.function_call_arguments.delta": "tool", "response.reasoning_text.delta": "reasoning"}


class Analysis:
    def __init__(self, save):
        self.save = save
        self.seq = 0
        self.complete = False
        self.issues = []
        self.usage = []
        self.usage_bytes = 0
        self.metrics = dict.fromkeys(("credits", "context_usage_percentage", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"))
        self.delta_chars = self.delta_bytes = 0
        self.extra_deltas = {}  # kind -> characters, present once a delta of that kind is seen
        self.extra_terminal = None  # from the first response.completed only; a repeat is the same output
        self.final_counts = None
        self.terminal = None
        self.stream_failed = False
        self.metering_events = 0

    def number(self, key, value, integer=False, nonnegative=False):
        try:
            if integer:
                if type(value) is not int or not 0 <= value <= 2**63 - 1:
                    raise ValueError()
            else:
                if type(value) not in (int, float):
                    raise ValueError()
                value = float(value)
                if not math.isfinite(value) or (nonnegative and value < 0):
                    raise ValueError()
            self.metrics[key] = value
        except (OverflowError, ValueError):
            self.metrics[key] = None
            if "invalid_usage_number" not in self.issues:
                self.issues.append("invalid_usage_number")

    def inspect(self, obj):
        if isinstance(obj, dict) and obj.get("object") == "response" and obj.get("status") in ("completed", "failed", "incomplete"):
            self.inspect({"type": "response." + obj["status"], "response": obj})
            return
        def walk(value, path=""):
            if isinstance(value, dict):
                for key, child in value.items():
                    location = f"{path}/{key}"
                    if "usage" in key.lower() and isinstance(child, (dict, list)):
                        usage = {"path": location, "value": child}
                        size = len(packed(usage).encode())
                        if self.usage_bytes + size <= 1024 * 1024:
                            self.usage.append(usage)
                            self.usage_bytes += size
                        elif "usage_summary_limit" not in self.issues:
                            self.issues.append("usage_summary_limit")
                    if key == "kiro:credits":
                        child = child if isinstance(child, dict) else {}
                        self.credit(child.get("unit"), child.get("value"))
                    elif key == "kiro:context_usage_percentage" and child is not None:
                        self.number("context_usage_percentage", child)
                    walk(child, location)
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    walk(child, f"{path}/{index}")
        walk(obj)
        if not isinstance(obj, dict):
            return
        kind = obj.get("type")
        if kind == "response.output_text.delta" and isinstance(obj.get("delta"), str):
            self.delta_chars += len(obj["delta"])
            self.delta_bytes += len(obj["delta"].encode())
        if kind in EXTRA_DELTAS:
            self.extra(EXTRA_DELTAS[kind], obj.get("delta"))
        response = obj.get("response")
        if kind in ("response.completed", "response.failed", "response.incomplete"):
            self.terminal = kind
            self.complete = kind == "response.completed"
        if kind == "error":
            self.terminal = "error"
        if isinstance(response, dict) and isinstance(response.get("output"), list) and kind in ("response.completed", "response.failed", "response.incomplete"):
            texts = list(output_text(response["output"]))
            self.final_counts = (sum(len(t) for t in texts), sum(len(t.encode()) for t in texts))
            if kind == "response.completed" and self.extra_terminal is None:
                self.extra_terminal = terminal_extra(response["output"])
        # These fields are exact observations only when present in an explicit usage object.
        usage = (response or {}).get("usage") if isinstance(response, dict) else obj.get("usage")
        if isinstance(usage, dict):
            for key in ("input_tokens", "output_tokens"):
                value = usage.get(key)
                if value is not None:
                    self.number(key, value, integer=True)
            details = usage.get("input_tokens_details")
            if isinstance(details, dict) and details.get("cached_tokens") is not None:
                self.number("cache_read_tokens", details["cached_tokens"], integer=True)

    def event(self, frame, lines, partial):
        data, name = [], "message"
        try:
            for line in lines:
                key, _, value = line.partition(b":")
                if value.startswith(b" "):
                    value = value[1:]
                if key == b"data":
                    data.append(value)
                elif key == b"event":
                    name = value.decode("utf-8")
            obj = None
            if data and not partial and b"\n".join(data) != b"[DONE]":
                obj = decoded_json(b"\n".join(data))
                self.inspect(obj)
        except (ValueError, UnicodeError, RecursionError):
            if "invalid_event_data" not in self.issues:
                self.issues.append("invalid_event_data")
            obj = None
        if partial:
            self.issues.append("unterminated_event")
        self.save(self.seq, name, frame, obj)
        self.seq += 1

    def message(self, frame, headers, payload, problem):
        """One event-stream message; the payload is parsed only after both CRCs pass."""
        kind, obj = headers.get(":message-type"), None
        name = headers.get(":event-type") or headers.get(":exception-type") or kind or "message"
        if problem:
            self.stream_failed = True
            if problem not in self.issues:
                self.issues.append(problem)
        else:
            if kind != "event":
                self.stream_failed, self.terminal = True, kind  # exception or error message
            try:
                obj = decoded_json(payload) if payload else None
                if kind == "event" and isinstance(obj, dict):
                    self.stream_event(name, obj)
            except (ValueError, UnicodeError, RecursionError):
                obj = None
                if "invalid_event_data" not in self.issues:
                    self.issues.append("invalid_event_data")
        self.save(self.seq, name, frame, obj)
        self.seq += 1

    def extra(self, name, text):
        self.extra_deltas[name] = self.extra_deltas.get(name, 0) + (len(text) if isinstance(text, str) else 0)

    def credit(self, unit, value):
        """kiro:credits and meteringEvent share one rule: only unit "credit" is a credit count."""
        if unit == "credit":
            self.number("credits", value, nonnegative=True)
        else:
            self.metrics["credits"] = None
            if "invalid_credit_unit" not in self.issues:
                self.issues.append("invalid_credit_unit")

    def stream_event(self, name, obj):
        """GenerateAssistantResponse ChatResponseStream members, named by :event-type."""
        self.inspect(obj)  # retains metadataEvent.tokenUsage among usage_objects
        if name == "assistantResponseEvent" and isinstance(obj.get("content"), str):
            self.delta_chars += len(obj["content"])
            self.delta_bytes += len(obj["content"].encode())
        elif name == "toolUseEvent":
            self.extra("tool", obj.get("input"))
        elif name == "reasoningContentEvent":
            self.extra("reasoning", obj.get("text"))
        elif name == "meteringEvent":
            self.metering_events += 1  # More than one keeps the last value; summary_json reports the count.
            self.credit(obj.get("unit"), obj.get("usage"))
        elif name == "contextUsageEvent" and obj.get("contextUsagePercentage") is not None:
            self.number("context_usage_percentage", obj["contextUsagePercentage"])
        elif name == "metadataEvent":
            if isinstance(obj.get("stopReason"), str) and not self.stream_failed:
                self.terminal = obj["stopReason"]
            usage = obj.get("tokenUsage")
            if isinstance(usage, dict):
                for key, field in (("output_tokens", "outputTokens"), ("cache_read_tokens", "cacheReadInputTokens"), ("cache_write_tokens", "cacheWriteInputTokens")):
                    if usage.get(field) is not None:
                        self.number(key, usage[field], integer=True)
                # input_tokens includes cached reads and writes, as on /v1/responses; any absent part leaves it unknown.
                parts = [usage.get(field) for field in ("uncachedInputTokens", "cacheReadInputTokens", "cacheWriteInputTokens")]
                if all(part is not None for part in parts):
                    self.number("input_tokens", sum(parts) if all(type(part) is int and part >= 0 for part in parts) else None, integer=True)

    def summary(self):
        chars, size = self.final_counts or (self.delta_chars, self.delta_bytes)
        # query.py adds these to output_text_chars for ~output; counted live so omitted payload copies cannot hide them.
        extra = {name: self.extra_deltas.get(name, (self.extra_terminal or {}).get(name, 0)) for name in ("tool", "reasoning")}
        return {"output_text_chars": chars, "output_text_bytes": size,
                "tool_chars": extra["tool"], "reasoning_chars": extra["reasoning"],
                "output_count_source": "terminal_output" if self.final_counts is not None else "deltas",
                "terminal": self.terminal, "usage_objects": self.usage,
                "metering_events": self.metering_events, "estimates": {}}


class Collector:
    """Callbacks parse each chunk and enqueue its payload copy without waiting for SQLite; one worker writes captures,
    and a store.Sealer compacts each one the worker finished."""

    OVERHEAD = 512  # tracemalloc: a queued item holds ~434 bytes and each event entry ~172 beyond payload bytes
    BATCH_ITEMS, BATCH_BYTES = 512, 4 * 1024 * 1024  # per write transaction: bounds lock hold and in-flight copies

    # Queue budget: one request at the 32 MiB API limit plus 8 MiB of streaming headroom.
    def __init__(self, path, max_bytes=40 * 1024 * 1024, warn_bytes=WARN_BYTES, retention_days=None):
        if min(max_bytes, warn_bytes) <= 0:
            raise ValueError("capture queue budget and payload warning must be positive")
        self.path = path
        self.warn_bytes, self.warned = warn_bytes, False
        db = open_database(path)
        try:
            self.writer_lock = lock_beside(path, ".capture.lock")
        except BaseException:
            db.close()
            raise
        try:
            db.executescript(SCHEMA)
        except BaseException:
            os.close(self.writer_lock)
            db.close()
            raise
        versions = [r[0] for r in db.execute("SELECT version FROM capture_meta")]
        if versions not in ([], [1], [2]):
            db.close()
            os.close(self.writer_lock)
            raise ValueError("unsupported capture schema version")
        # Version 2 seals new captures, which an older collector cannot read; it refuses the store instead.
        db.execute("UPDATE capture_meta SET version=2" if versions else "INSERT INTO capture_meta VALUES (2)")
        db.execute("UPDATE captures SET state='incomplete',transport_ended=0,issues_json='[\"interrupted_capture\"]' WHERE state='recording'")
        # Migration: captures a v1 collector, or a v2 one before this queue, staged are sealed as backlog.
        db.execute("INSERT OR IGNORE INTO pending_seals SELECT id FROM captures c WHERE NOT EXISTS(SELECT 1 FROM capture_facts f WHERE f.capture_id=c.id)")
        db.commit()
        import store
        self.stored_bytes = store.payload_bytes(db)
        # Start order seals each request's base before the requests built on it, so the sealer's request cache finds it.
        backlog = [ident for (ident,) in db.execute(
            "SELECT p.capture_id FROM pending_seals p JOIN captures c ON c.id=p.capture_id WHERE c.state!='recording' ORDER BY c.started_utc_ns,c.id")]
        freelist, pages = (db.execute(pragma).fetchone()[0] for pragma in ("PRAGMA freelist_count", "PRAGMA page_count"))
        try:
            if freelist > pages / 2:
                compact(db)
        except sqlite3.OperationalError:  # another connection holding the store must not make selected Kiro requests 503
            print("Kiro capture: startup vacuum failed (OperationalError); capture continues", file=sys.stderr)
        db.close()
        self.queue = queue.Queue()  # bounded by max_bytes in _put
        self.lock = threading.Lock()
        self.states = {}
        self.queued_bytes, self.max_bytes = 0, max_bytes
        self.carry = None  # an item _batch took that starts the next batch
        self.failure = None
        self.stopping = False
        try:  # created after self.lock, which its callback takes
            self.sealer = store.Sealer(path, self._count, retention_days, backlog)
        except BaseException:
            os.close(self.writer_lock)
            raise
        self.thread = threading.Thread(target=self._worker, name="kiro-capture", daemon=True)
        self.thread.start()

    def _retain(self, *payloads):
        """Payloads are retained through the retention window; the worker counts each copy it writes."""
        self._count(sum(len(p) if isinstance(p, bytes) else len(p.encode()) for p in payloads if p is not None))

    def _count(self, delta):
        with self.lock:
            self.stored_bytes += delta
            stored, warn = self.stored_bytes, self.stored_bytes > self.warn_bytes and not self.warned
            self.warned = self.warned or warn
        if warn:
            print(f"Kiro capture: retained payloads reached {stored} bytes, past the {self.warn_bytes}-byte warning; "
                  "capture continues, see docs/usage-tracking.md to retire the store", file=sys.stderr)

    def check(self):
        if self.failure:
            raise RuntimeError("Kiro capture database worker failed; capture stopped") from self.failure
        if self.stopping:
            raise RuntimeError("Kiro capture is closed")

    def begin(self, metadata, body):
        self.check()
        ident = uuid.uuid4().hex
        stamp = (time.time_ns(), time.monotonic_ns())
        state = dict(id=ident, metadata=metadata, start=stamp,
                     pending=0, dropped_chunks=0, dropped_bytes=0, observed_chunks=0,
                     observed_bytes=0, done=False, response={}, issues=[])
        details, state["hashes"] = request_details(body, state["issues"], "target" in metadata)
        state["metadata"].update(details)
        target = state["parse"] = dict(hash=hashlib.sha256(), decoder=None, encoding=None, json=bytearray(), stamp=(0, 0), seq=-1)  # _parse sets events/size/budget
        target["analysis"] = Analysis(lambda *saved: self._stage(target, *saved))
        target["sse"] = SSE(target["analysis"].event)
        target["eventstream"] = EventStream(target["analysis"].message)
        with self.lock:
            if len(self.states) >= 256:
                raise CaptureCapacityError("Kiro capture active-flow limit reached; selected request was not captured")
            self.states[ident] = state
        self._put(state, "request", body, -1, stamp, self.OVERHEAD + len(body))
        return ident

    def headers(self, ident, metadata):
        self.check()
        with self.lock:
            self.states[ident]["response"] = metadata

    def _stage(self, target, seq, name, frame, obj):
        """Copy one already-analyzed event into the chunk's queue item while the item fits the queue budget.

        Past it the item can no longer be queued (size inf) and later events are never copied: a chunk of 360,000 blank SSE
        frames otherwise staged ~87 MB of copies before _put refused them all."""
        if target["size"] <= target["budget"]:
            text = event_text(obj)
            target["size"] += len(frame) + len(text or "") + self.OVERHEAD
            target["events"].append((seq, name, frame, text))
        if target["size"] > target["budget"]:
            target["size"], target["events"] = math.inf, []

    def _put(self, state, kind, data, seq, stamp, size, application=None, events=()):
        """size: the item's queue charge, inf when _stage already overflowed the budget."""
        self.check()
        with self.lock:
            if self.queued_bytes + size > self.max_bytes:
                state["dropped_chunks"] += 1
                state["dropped_bytes"] += len(data)
                if kind + "_payload_omitted" not in state["issues"]:
                    state["issues"].append(kind + "_payload_omitted")
                    print(f"Kiro capture {state['id']}: payload queue full; {kind} payload omitted, usage still parsed", file=sys.stderr)
                return
            state["pending"] += 1
            self.queued_bytes += size
            self.queue.put_nowait((state, kind, bytes(data), seq, stamp, application, events, size))

    def chunk(self, ident, data):
        self.check()
        stamp = (time.time_ns(), time.monotonic_ns())
        with self.lock:
            state = self.states[ident]
            seq = state["observed_chunks"]
            state["observed_chunks"] += 1
            state["observed_bytes"] += len(data)
        try:
            application, events, size = self._parse(state, data, seq, stamp)
        except Exception as error:  # A parser defect stops capture like a writer failure, never the passing stream.
            self.failure = error
            raise RuntimeError("Kiro capture parser failed; capture stopped") from error
        self._put(state, "response", data, seq, stamp, size, application, events)
        return data

    def finish(self, ident, transport_ended=True, error=None):
        self.check()
        with self.lock:
            state = self.states[ident]
            state.update(done=True, ended=(time.time_ns(), time.monotonic_ns()), transport_ended=transport_ended)
            if error:
                state["issues"].append(error)  # caller supplies a fixed category, never an exception body

    def close(self):
        if self.stopping:
            return
        with self.lock:
            for state in self.states.values():
                if not state["done"]:
                    state.update(done=True, ended=(time.time_ns(), time.monotonic_ns()), transport_ended=False)
                    state["issues"].append("collector_shutdown")
            self.stopping = True
        self.thread.join()
        self.sealer.close()  # a worker failure still seals what it committed; one sealer while the flock is held
        os.close(self.writer_lock)
        if self.failure:
            raise RuntimeError("Kiro capture database worker failed") from self.failure

    def _batch(self):
        """Block for one item, then take what is already queued while it fits BATCH_ITEMS and BATCH_BYTES.

        An item that would overflow the batch is carried into the next one, so an item larger than BATCH_BYTES
        (a request up to 32 MiB) is always a batch of its own."""
        batch, size = [], 0
        while len(batch) < self.BATCH_ITEMS:
            try:
                item = self.carry or (self.queue.get_nowait() if batch else self.queue.get(timeout=0.02))
            except queue.Empty:
                break
            self.carry = None
            if batch and size + item[-1] > self.BATCH_BYTES:
                self.carry = item
                break
            batch.append(item)
            size += item[-1]
        return batch

    def _worker(self):
        try:
            db = open_database(self.path)
            live = set()
            while True:
                batch = self._batch()
                if batch:
                    writes = [self._prepare(*item[:-1]) for item in batch]  # compression runs before the write lock
                    db.execute("BEGIN IMMEDIATE")
                    for (state, *_), statements in zip(batch, writes):
                        if state["id"] not in live:
                            self._initialize(db, state)
                            live.add(state["id"])
                        for statement in statements:
                            db.execute(*statement)
                    db.commit()
                    with self.lock:
                        for state, *_, size in batch:
                            state["pending"] -= 1
                            self.queued_bytes -= size
                with self.lock:
                    finished = [s for s in self.states.values() if s["done"] and not s["pending"]]
                for state in finished:
                    ident = state["id"]
                    db.execute("BEGIN IMMEDIATE")
                    if ident not in live:
                        self._initialize(db, state)
                    live.discard(ident)
                    self._finalize(db, state)
                    with self.lock:
                        del self.states[ident]
                    self.sealer.put(ident)
                with self.lock:
                    if self.stopping and not self.states:
                        break
            db.close()
        except BaseException as error:
            self.failure = error
            print("Kiro capture database worker failed; stop capture and inspect the DB", file=sys.stderr)
            try:
                db.rollback()
                db.execute("UPDATE captures SET state='incomplete',issues_json='[\"collector_failure\"]' WHERE state='recording'")
                db.commit()
            except (sqlite3.Error, UnboundLocalError):
                pass  # Rows remain recording if the DB cannot be written.
        finally:
            if "db" in locals():
                db.close()

    def _initialize(self, db, state):
        db.execute("INSERT INTO captures (id,started_utc_ns,started_mono_ns,metadata_json,response_json,fingerprints_json,state) VALUES (?,?,?,?,?,?,'recording')", (state["id"], *state["start"], packed(state["metadata"]), packed(state["response"]), packed(state["hashes"])))
        db.execute("INSERT INTO pending_seals VALUES (?)", (state["id"],))  # queued with the row it seals

    def _event_rows(self, state, events, seq, stamp):
        rows = []
        for event_seq, name, frame, text in events:
            raw = gzip.compress(frame, GZIP_LEVEL)
            self._retain(raw, text)
            rows.append(("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", (state["id"], event_seq, seq, *stamp, name, raw, text)))
        return rows

    def _prepare(self, state, kind, data, seq, stamp, application, events):
        """Compress and count retained payload bytes; returns the statements for the write transaction."""
        if kind == "request":
            payload = gzip.compress(data, GZIP_LEVEL)
            self._retain(payload)
            return [("UPDATE captures SET request_gzip=?,request_sha256=?,fingerprints_json=?,metadata_json=? WHERE id=?", (payload, digest(data), packed(state["hashes"]), packed(state["metadata"]), state["id"]))]
        entity = gzip.compress(data, GZIP_LEVEL)
        app = entity if application is data else gzip.compress(application, GZIP_LEVEL) if application is not None else None  # identity: one compression
        self._retain(entity, app)
        return [("INSERT INTO chunks VALUES (?,?,?,?,?,?)", (state["id"], seq, *stamp, entity, app)), *self._event_rows(state, events, seq, stamp)]

    def _parse(self, state, data, seq, stamp):
        """Decode and frame every observed byte in arrival order; returns application bytes, staged events and the queue charge."""
        target = state["parse"]
        target.update(seq=seq, stamp=stamp, events=[], size=self.OVERHEAD + len(data), budget=self.max_bytes - self.queued_bytes)
        response = state["response"]
        encoding = content_encoding(response)
        if target["encoding"] is None:
            target["encoding"] = encoding
            target["decoder"] = content_decoder(encoding)
            if encoding not in ("identity", "gzip", "deflate"):
                state["issues"].append("unsupported_content_encoding")
        application = None
        if "decode_error" not in state["issues"] and encoding in ("identity", "gzip", "deflate"):
            application, ok = decode_chunk(target["decoder"], data)
            if not ok:
                state["issues"].append("decode_error")
                target["encoding"] = "invalid"
            else:
                target["hash"].update(application)
                target["size"] += len(application) if application is not data else 0
                parser = target.get(framing_kind(response, "target" in state["metadata"]))
                if parser:
                    parser.feed(application)
                elif len(target["json"]) + len(application) <= 4 * 1024 * 1024:
                    target["json"].extend(application)
                else:
                    if "json_parse_limit" not in state["issues"]:
                        state["issues"].append("json_parse_limit")
        return application, target["events"], target["size"]

    def _finalize(self, db, state):
        target = state["parse"]
        analysis = target["analysis"]
        response = state["response"]
        if target["decoder"] and target["decoder"].unused_data:
            state["issues"].append("trailing_content_encoding")
        if target["decoder"] and not target["decoder"].eof:
            state["issues"].append("truncated_content_encoding")
        whole = not any(x in state["issues"] for x in ("decode_error", "unsupported_content_encoding", "truncated_content_encoding", "trailing_content_encoding"))
        parser = target.get(framing_kind(response, "target" in state["metadata"]))
        if parser:
            target.update(events=[], size=0, budget=math.inf)  # The EOF tail is written here, never queued.
            parser.feed(b"", final=True)
            for statement in self._event_rows(state, target["events"], target["seq"], target["stamp"]):
                db.execute(*statement)
            if parser.disabled:
                state["issues"].append("event_parse_limit")
            if parser is target["eventstream"]:
                # Event streams have no terminal event: completion is EOF on a message boundary after at least one message, with no exception or framing failure.
                analysis.complete = whole and analysis.seq > 0 and not (analysis.stream_failed or parser.disabled)
        elif target["json"] and "json_parse_limit" not in state["issues"]:
            try:
                obj = decoded_json(target["json"])
                analysis.inspect(obj)
                parsed = packed(obj)
                self._retain(parsed)
                db.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", (state["id"], 0, target["seq"], *target["stamp"], "json", None, parsed))
            except (ValueError, UnicodeError, RecursionError):
                state["issues"].append("invalid_json")
        summary = analysis.summary()
        if summary["usage_objects"]:
            self._retain(packed(summary["usage_objects"]))
        issues = sorted(set(state["issues"] + analysis.issues))
        if not analysis.complete:
            issues.append("missing_completion")
        complete = state["transport_ended"] and not set(issues) - OMISSIONS
        values = ( *state["ended"], packed(state["metadata"]), packed(response),
                  target["hash"].hexdigest() if whole else None,
                  packed(summary), state["observed_chunks"], state["observed_bytes"], state["dropped_chunks"], state["dropped_bytes"], int(state["transport_ended"]), int(analysis.complete), "complete" if complete else "incomplete", packed(issues),
                  *analysis.metrics.values(), state["id"])
        db.execute("UPDATE captures SET ended_utc_ns=?,ended_mono_ns=?,metadata_json=?,response_json=?,response_sha256=?,summary_json=?,observed_chunks=?,observed_bytes=?,dropped_chunks=?,dropped_bytes=?,transport_ended=?,completion_seen=?,state=?,issues_json=?,credits=?,context_usage_percentage=?,input_tokens=?,output_tokens=?,cache_read_tokens=?,cache_write_tokens=? WHERE id=?", values)
        db.commit()


def json_lines(names, rows):
    """One packed JSON object per row, BLOB columns as base64."""
    for row in rows:
        print(packed({name: base64.b64encode(value).decode() if isinstance(value, bytes) else value for name, value in zip(names, row)}))


def main():
    parser = argparse.ArgumentParser(description="Offline inspection; unpack writes private payloads to stdout")
    parser.add_argument("--db", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--json", action="store_true", help="write the existing complete JSON object per capture")
    unpack = sub.add_parser("unpack")
    unpack.add_argument("id")
    unpack.add_argument("mode", choices=("request", "transport", "decoded", "chunks", "events"),
                        help="request bytes, response entity or application bytes, or chunk or event rows as JSON lines")
    args = parser.parse_args()
    path = Path(args.db).expanduser().resolve(strict=True)
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    if args.command == "list":
        rows = db.execute("SELECT id,state,observed_bytes,dropped_bytes,credits,context_usage_percentage,issues_json FROM captures ORDER BY started_utc_ns")
        if args.json:
            for row in rows:
                print(packed(dict(row)))
        else:
            from display import table
            print(table(["Capture", "State", "Bytes", "Dropped", "Credits", "Context %", "Issues"],
                        [[row["id"], row["state"], row["observed_bytes"], row["dropped_bytes"],
                          row["credits"], row["context_usage_percentage"], row["issues_json"]] for row in rows]))
    else:
        import store
        with store.snapshot(db):
            capture = db.execute("SELECT state,observed_chunks,response_sha256 FROM captures WHERE id=?", (args.id,)).fetchone()
            if capture is None:
                parser.error("unknown capture id")
            if {"capture_facts", "sealed_responses"} <= store.tables(db) and db.execute(
                    "SELECT EXISTS(SELECT 1 FROM capture_facts WHERE capture_id=?) AND "
                    "NOT EXISTS(SELECT 1 FROM sealed_responses WHERE capture_id=?)", (args.id, args.id)).fetchone()[0]:
                parser.exit(1, "capture payloads expired by retention\n")
            if capture[0] != "complete":
                print("warning: unpacking incomplete evidence", file=sys.stderr)
            try:
                if args.mode == "request":
                    body = store.request_body(db, args.id)
                    if body is None:
                        parser.exit(1, "request payload unavailable\n")
                    sys.stdout.buffer.write(body)
                else:
                    chunks, events = store.response_rows(db, args.id)
            except ValueError as error:
                parser.exit(2, f"capture payload failed verification: {error}\n")
            if args.mode == "chunks":
                json_lines(("seq", "utc_ns", "mono_ns", "entity", "application"), chunks)
            elif args.mode == "events":
                json_lines(("seq", "chunk_seq", "utc_ns", "mono_ns", "event_name", "frame", "data_json"), events)
            elif args.mode != "request":
                column, expected, written = 3 if args.mode == "transport" else 4, 0, hashlib.sha256()
                # A queue-omitted chunk leaves no row, even in a complete capture; a gap or short tail is missing bytes.
                for chunk in chunks:
                    if chunk[0] != expected or chunk[column] is None:
                        break
                    sys.stdout.buffer.write(chunk[column])
                    written.update(chunk[column])
                    expected += 1
                if expected != capture[1]:
                    parser.exit(1, "requested payload bytes unavailable (capture is incomplete)\n")
                # The collector hashes every decoded byte, and records the hash only when nothing failed to decode.
                if args.mode == "decoded" and capture[2] and written.hexdigest() != capture[2]:
                    parser.exit(2, "capture payload failed verification: response hash mismatch\n")
    db.close()


if __name__ == "__main__":
    main()

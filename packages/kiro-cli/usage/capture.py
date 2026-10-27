"""Private, independent Kiro calibration evidence store; no provider calls."""

import argparse
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
"""


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
    except sqlite3.Error:
        db.close()
        raise
    db.row_factory = sqlite3.Row
    return db


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


def digest(value):
    return hashlib.sha256(value).hexdigest()


def child(value, *keys):
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def request_details(body, issues=None):
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
        conversation = obj.get("conversationState")
        if isinstance(conversation, dict):
            # GenerateAssistantResponse: agent mode travels as a header; tools ride on the current message.
            message = child(conversation, "currentMessage")
            fields = {"model": child(message, "userInputMessage", "modelId"),
                      "effort": child(obj, "additionalModelRequestFields", "output_config", "effort") or child(obj, "additionalModelRequestFields", "reasoning", "effort"),
                      "kiro:conversation_id": conversation.get("conversationId"),
                      "kiro:root_conversation_id": conversation.get("rootConversationId")}
            components = {key: value for key, value in (("currentMessage", message), ("history", conversation.get("history")), ("systemPrompt", obj.get("systemPrompt")),
                                                        ("tools", child(message, "userInputMessage", "userInputMessageContext", "tools"))) if value is not None}
            items, items_key = conversation.get("history"), "history_items"
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

    def __init__(self, emit, limit=4 * 1024 * 1024):
        self.emit, self.limit = emit, limit
        self.buffer = b""
        self.frame = bytearray()
        self.lines = []
        self.disabled = False

    def feed(self, data, final=False):
        if self.disabled:
            return
        self.buffer += data
        while self.buffer:
            match = re.search(b"\r\n|\r|\n", self.buffer)
            if not match or (match.group() == b"\r" and match.end() == len(self.buffer) and not final):
                break
            raw, self.buffer = self.buffer[:match.end()], self.buffer[match.end():]
            self.frame.extend(raw)
            line = raw[:match.start()]
            if line:
                self.lines.append(line)
            else:
                self.emit(bytes(self.frame), self.lines, False)
                self.frame.clear()
                self.lines = []
            if len(self.frame) > self.limit:
                self.disabled = True
                self.buffer = b""
                return
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
        self.final_counts = None
        self.terminal = None
        self.stream_failed = False

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
                        if isinstance(child, dict) and child.get("unit") == "credit":
                            self.number("credits", child.get("value"), nonnegative=True)
                        else:
                            self.metrics["credits"] = None
                            if "invalid_credit_unit" not in self.issues:
                                self.issues.append("invalid_credit_unit")
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
        response = obj.get("response")
        if kind in ("response.completed", "response.failed", "response.incomplete"):
            self.terminal = kind
            self.complete = kind == "response.completed"
        if kind == "error":
            self.terminal = "error"
        if isinstance(response, dict) and isinstance(response.get("output"), list) and kind in ("response.completed", "response.failed", "response.incomplete"):
            texts = list(output_text(response["output"]))
            self.final_counts = (sum(len(t) for t in texts), sum(len(t.encode()) for t in texts))
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

    def stream_event(self, name, obj):
        """GenerateAssistantResponse ChatResponseStream members, named by :event-type."""
        self.inspect(obj)  # retains metadataEvent.tokenUsage among usage_objects
        if name == "assistantResponseEvent" and isinstance(obj.get("content"), str):
            self.delta_chars += len(obj["content"])
            self.delta_bytes += len(obj["content"].encode())
        elif name == "meteringEvent":
            if obj.get("unit") == "credit":
                self.number("credits", obj.get("usage"), nonnegative=True)
            else:
                self.metrics["credits"] = None
                if "invalid_credit_unit" not in self.issues:
                    self.issues.append("invalid_credit_unit")
        elif name == "contextUsageEvent" and obj.get("contextUsagePercentage") is not None:
            self.number("context_usage_percentage", obj["contextUsagePercentage"])
        elif name == "metadataEvent":
            if isinstance(obj.get("stopReason"), str):
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
        return {"output_text_chars": chars, "output_text_bytes": size,
                "output_count_source": "terminal_output" if self.final_counts is not None else "deltas",
                "terminal": self.terminal, "usage_objects": self.usage,
                "estimates": {}}


class Collector:
    """Callbacks enqueue without waiting for SQLite; one worker owns all writes."""

    def __init__(self, path, max_bytes=8 * 1024 * 1024, max_items=256, max_stored_bytes=256 * 1024 * 1024):
        if min(max_bytes, max_items, max_stored_bytes) <= 0:
            raise ValueError("capture budgets must be positive")
        self.path = path
        self.max_stored_bytes = max_stored_bytes
        db = open_database(path)
        self.writer_lock = os.open(str(Path(path).expanduser().absolute()) + ".capture.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.writer_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            db.executescript(SCHEMA)
        except BaseException:
            os.close(self.writer_lock)
            db.close()
            raise
        versions = [r[0] for r in db.execute("SELECT version FROM capture_meta")]
        if versions and versions != [1]:
            db.close()
            os.close(self.writer_lock)
            raise ValueError("unsupported capture schema version")
        if not versions:
            db.execute("INSERT INTO capture_meta VALUES (1)")
        db.execute("UPDATE captures SET state='incomplete',transport_ended=0,issues_json='[\"interrupted_capture\"]' WHERE state='recording'")
        db.commit()
        self.retention_stopped = False
        self.stored_bytes = sum(db.execute(query).fetchone()[0] or 0 for query in (
            "SELECT SUM(length(request_gzip)) FROM captures",
            "SELECT SUM(COALESCE(length(entity_gzip),0)+COALESCE(length(application_gzip),0)) FROM chunks",
            "SELECT SUM(COALESCE(length(frame_gzip),0)+COALESCE(length(CAST(data_json AS BLOB)),0)) FROM events"))
        self.stored_bytes += sum(len(packed(usage).encode())
                                 for row in db.execute("SELECT summary_json FROM captures WHERE summary_json IS NOT NULL")
                                 if (usage := json.loads(row[0]).get("usage_objects")))
        db.close()
        self.queue = queue.Queue(max_items)
        self.lock = threading.Lock()
        self.states = {}
        self.queued_bytes, self.max_bytes = 0, max_bytes
        self.failure = None
        self.stopping = False
        self.thread = threading.Thread(target=self._worker, name="kiro-capture", daemon=True)
        self.thread.start()

    def _retain(self, state, *payloads):
        size = sum(len(p) if isinstance(p, bytes) else len(p.encode()) for p in payloads if p is not None)
        if self.retention_stopped or self.stored_bytes + size > self.max_stored_bytes:
            self.retention_stopped = True
            if "storage_budget" not in state["issues"]:
                state["issues"].append("storage_budget")
                print(f"Kiro capture {state['id']}: storage budget exhausted; evidence incomplete", file=sys.stderr)
            return False
        self.stored_bytes += size
        return True

    def check(self):
        if self.failure:
            raise RuntimeError("Kiro capture database worker failed; capture stopped") from self.failure
        if self.stopping:
            raise RuntimeError("Kiro capture is closed")

    def begin(self, metadata, body):
        self.check()
        ident = uuid.uuid4().hex
        state = dict(id=ident, metadata=metadata, start=(time.time_ns(), time.monotonic_ns()),
                     pending=0, dropped_chunks=0, dropped_bytes=0, observed_chunks=0,
                     observed_bytes=0, done=False, response={}, issues=[], response_gap=False)
        details, state["hashes"] = request_details(body, state["issues"])
        state["metadata"].update(details)
        with self.lock:
            if len(self.states) >= 256:
                raise CaptureCapacityError("Kiro capture active-flow limit reached; selected request was not captured")
            self.states[ident] = state
        self._put(state, "request", body, -1)
        return ident

    def headers(self, ident, metadata):
        self.check()
        with self.lock:
            self.states[ident]["response"] = metadata

    def _put(self, state, kind, data, seq):
        self.check()
        stamp = (time.time_ns(), time.monotonic_ns())
        with self.lock:
            if self.queued_bytes + len(data) > self.max_bytes or self.queue.full():
                state["dropped_chunks"] += 1
                state["dropped_bytes"] += len(data)
                state["response_gap"] |= kind == "response"
                if "queue_overflow" not in state["issues"]:
                    state["issues"].append("queue_overflow")
                    print(f"Kiro capture {state['id']}: queue overflow; evidence incomplete", file=sys.stderr)
                return
            state["pending"] += 1
            self.queued_bytes += len(data)
            self.queue.put_nowait((state, kind, bytes(data), seq, stamp))

    def chunk(self, ident, data):
        self.check()
        with self.lock:
            state = self.states[ident]
            seq = state["observed_chunks"]
            state["observed_chunks"] += 1
            state["observed_bytes"] += len(data)
        self._put(state, "response", data, seq)
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
        os.close(self.writer_lock)
        if self.failure:
            raise RuntimeError("Kiro capture database worker failed") from self.failure

    def _worker(self):
        try:
            db = open_database(self.path)
            live = {}
            while True:
                try:
                    item = self.queue.get(timeout=0.02)
                except queue.Empty:
                    item = None
                if item:
                    state, kind, data, seq, stamp = item
                    ident = state["id"]
                    db.execute("BEGIN IMMEDIATE")
                    if ident not in live:
                        live[ident] = self._initialize(db, state)
                    target = live[ident]
                    if kind == "request":
                        payload = gzip.compress(data)
                        if not self._retain(state, payload):
                            state["dropped_chunks"] += 1
                            state["dropped_bytes"] += len(data)
                            payload = None
                        db.execute("UPDATE captures SET request_gzip=?,request_sha256=?,fingerprints_json=?,metadata_json=? WHERE id=?", (payload, digest(data), packed(state["hashes"]), packed(state["metadata"]), ident))
                    else:
                        self._store_chunk(db, state, target, data, seq, stamp)
                    db.commit()
                    with self.lock:
                        state["pending"] -= 1
                        self.queued_bytes -= len(data)
                with self.lock:
                    finished = [s for s in self.states.values() if s["done"] and not s["pending"]]
                for state in finished:
                    ident = state["id"]
                    db.execute("BEGIN IMMEDIATE")
                    target = live.pop(ident) if ident in live else self._initialize(db, state)
                    self._finalize(db, state, target)
                    with self.lock:
                        del self.states[ident]
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
        ident = state["id"]
        db.execute("INSERT INTO captures (id,started_utc_ns,started_mono_ns,metadata_json,response_json,fingerprints_json,state) VALUES (?,?,?,?,?,?,'recording')", (ident, *state["start"], packed(state["metadata"]), packed(state["response"]), packed(state["hashes"])))
        target = dict(hash=hashlib.sha256(), decoder=None, encoding=None, json=bytearray(), stamp=(0, 0), seq=-1)
        def save(seq, name, frame, obj):
            raw, parsed = gzip.compress(frame), packed(obj) if obj is not None else None
            if not self._retain(state, raw, parsed):
                raw = parsed = None
            db.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", (ident, seq, target["seq"], *target["stamp"], name, raw, parsed))
        target["analysis"] = Analysis(save)
        target["sse"] = SSE(target["analysis"].event)
        target["eventstream"] = EventStream(target["analysis"].message)
        return target

    @staticmethod
    def framing(target, response):
        content_type = response.get("content_type", "")
        for media, key in (("text/event-stream", "sse"), ("application/vnd.amazon.eventstream", "eventstream")):
            if media in content_type:
                return target[key]

    def _store_chunk(self, db, state, target, data, seq, stamp):
        target.update(seq=seq, stamp=stamp)
        response = state["response"]
        encoding = response.get("content_encoding", "identity").lower().strip() or "identity"
        if target["encoding"] is None:
            target["encoding"] = encoding
            if encoding in ("gzip", "deflate"):
                target["decoder"] = zlib.decompressobj(16 + zlib.MAX_WBITS if encoding == "gzip" else zlib.MAX_WBITS)
            elif encoding != "identity":
                state["issues"].append("unsupported_content_encoding")
        application = None
        try:
            if not state["response_gap"] and "decode_error" not in state["issues"] and encoding in ("identity", "gzip", "deflate"):
                application = target["decoder"].decompress(data, 16 * 1024 * 1024 + 1) if target["decoder"] else data
                if len(application) > 16 * 1024 * 1024 or (target["decoder"] and target["decoder"].unconsumed_tail):
                    raise zlib.error("decompressed chunk exceeds safety limit")
                target["hash"].update(application)
                parser = self.framing(target, response)
                if parser:
                    parser.feed(application)
                elif len(target["json"]) + len(application) <= 4 * 1024 * 1024:
                    target["json"].extend(application)
                else:
                    if "json_parse_limit" not in state["issues"]:
                        state["issues"].append("json_parse_limit")
        except zlib.error:
            state["issues"].append("decode_error")
            target["encoding"] = "invalid"
        entity = gzip.compress(data)
        app = gzip.compress(application) if application is not None else None
        if not self._retain(state, entity, app):
            state["dropped_chunks"] += 1
            state["dropped_bytes"] += len(data)
            entity = app = None
        db.execute("INSERT INTO chunks VALUES (?,?,?,?,?,?)", (state["id"], seq, *stamp, entity, app))

    def _finalize(self, db, state, target):
        analysis = target["analysis"]
        response = state["response"]
        if target["decoder"] and target["decoder"].unused_data:
            state["issues"].append("trailing_content_encoding")
        if target["decoder"] and not target["decoder"].eof:
            state["issues"].append("truncated_content_encoding")
        whole = not state["response_gap"] and not any(x in state["issues"] for x in ("decode_error", "unsupported_content_encoding", "truncated_content_encoding", "trailing_content_encoding"))
        parser = self.framing(target, response)
        if parser:
            parser.feed(b"", final=True)
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
                if not self._retain(state, parsed):
                    parsed = None
                db.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", (state["id"], 0, target["seq"], *target["stamp"], "json", None, parsed))
            except (ValueError, UnicodeError, RecursionError):
                state["issues"].append("invalid_json")
        summary = analysis.summary()
        if summary["usage_objects"] and not self._retain(state, packed(summary["usage_objects"])):
            summary["usage_objects"] = []
        issues = sorted(set(state["issues"] + analysis.issues))
        if not analysis.complete:
            issues.append("missing_completion")
        complete = state["transport_ended"] and not issues
        values = ( *state["ended"], packed(state["metadata"]), packed(response),
                  target["hash"].hexdigest() if whole else None,
                  packed(summary), state["observed_chunks"], state["observed_bytes"], state["dropped_chunks"], state["dropped_bytes"], int(state["transport_ended"]), int(analysis.complete), "complete" if complete else "incomplete", packed(issues),
                  *analysis.metrics.values(), state["id"])
        db.execute("UPDATE captures SET ended_utc_ns=?,ended_mono_ns=?,metadata_json=?,response_json=?,response_sha256=?,summary_json=?,observed_chunks=?,observed_bytes=?,dropped_chunks=?,dropped_bytes=?,transport_ended=?,completion_seen=?,state=?,issues_json=?,credits=?,context_usage_percentage=?,input_tokens=?,output_tokens=?,cache_read_tokens=?,cache_write_tokens=? WHERE id=?", values)
        db.commit()


def main():
    parser = argparse.ArgumentParser(description="Offline inspection; replay writes private payloads to stdout")
    parser.add_argument("--db", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--json", action="store_true", help="write the existing complete JSON object per capture")
    replay = sub.add_parser("replay")
    replay.add_argument("id")
    replay.add_argument("--entity", action="store_true", help="replay encoded response entity bytes")
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
        capture = db.execute("SELECT state FROM captures WHERE id=?", (args.id,)).fetchone()
        if capture is None:
            parser.error("unknown capture id")
        if capture[0] != "complete":
            print("warning: replaying incomplete evidence", file=sys.stderr)
        column = "entity_gzip" if args.entity else "application_gzip"
        for row in db.execute(f"SELECT {column} FROM chunks WHERE capture_id=? ORDER BY seq", (args.id,)):
            if row[0] is None:
                parser.exit(1, "requested payload bytes unavailable (capture is incomplete)\n")
            sys.stdout.buffer.write(gzip.decompress(row[0]))
    db.close()


if __name__ == "__main__":
    main()

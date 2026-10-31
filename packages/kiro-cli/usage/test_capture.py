"""Synthetic offline contracts; no mitmproxy dependency, CLI launches or real data."""

import contextlib
import functools
import gzip
import io
import json
import os
from pathlib import Path
import runtime
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import patch

from capture import DECODE_LIMIT, Collector, EventStream, SSE, digest, open_database, request_details
from mitm_addon import UsageCapture


def event(obj, newline=b"\n"):
    return b"data: " + json.dumps(obj, ensure_ascii=False).encode() + newline + newline


def completed(text="é🙂"):
    return {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}, {"type": "reasoning", "summary": [{"text": "private reasoning"}]}, {"type": "function_call", "arguments": "{}"}], "usage": {"kiro:credits": {"unit": "credit", "unit_plural": "credits", "value": 0.25}, "kiro:context_usage_percentage": 12.3, "unknown": {"future": True}}}}


def aws_message(headers, payload=b"", extra=b"", corrupt=0):
    """Synthetic application/vnd.amazon.eventstream message; string headers plus optional raw header bytes."""
    raw = b"".join(bytes([len(k)]) + k.encode() + b"\x07" + struct.pack(">H", len(v.encode())) + v.encode() for k, v in headers.items()) + extra
    prelude = struct.pack(">II", 16 + len(raw) + len(payload), len(raw))
    message = prelude + struct.pack(">I", zlib.crc32(prelude)) + raw + payload
    return message + struct.pack(">I", zlib.crc32(message) ^ corrupt)


def aws_event(name, obj, **options):
    return aws_message({":message-type": "event", ":event-type": name, ":content-type": "application/json"}, json.dumps(obj).encode(), **options)


EVENTSTREAM = "application/vnd.amazon.eventstream"


def chatty(count=500):
    """A long stream of small delta chunks; usage arrives only in the final event."""
    return [event({"type": "response.output_text.delta", "delta": "word "}) for _ in range(count)] + [event(completed())]


class SlowCommits(sqlite3.Connection):
    """Every commit pays a synthetic 20 ms device flush."""
    commits = 0

    def commit(self):
        type(self).commits += 1
        time.sleep(.02)
        super().commit()


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "private" / "capture.sqlite3"

    def run_capture(self, parts, encoding="identity", finish=True, content_type="text/event-stream", **options):
        writer = Collector(self.path, **options)
        ident = writer.begin({"host": "runtime.kiro.dev"}, b'{"model":"synthetic","metadata":{"kiro:conversation_id":"sess_fake"},"tools":[]}')
        writer.headers(ident, {"content_type": content_type, "content_encoding": encoding})
        for part in parts:
            self.assertIs(writer.chunk(ident, part), part)
        if finish:
            writer.finish(ident)
        writer.close()
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        self.addCleanup(db.close)
        row = db.execute("SELECT * FROM captures WHERE id=?", (ident,)).fetchone()
        return db, row

    def test_unicode_all_split_boundaries_and_final_counts(self):
        body = event({"type": "response.output_text.delta", "delta": "é🙂"}) + event(completed())
        # Every byte boundary, including inside Unicode and CRLF, is exercised by one-byte chunks.
        db, row = self.run_capture([body[i:i+1] for i in range(len(body))])
        self.assertEqual(row["state"], "complete")
        self.assertEqual(row["response_sha256"], digest(body))
        self.assertEqual(row["credits"], .25)
        self.assertIsNone(row["input_tokens"])
        self.assertIsNone(row["cache_read_tokens"])
        summary = json.loads(row["summary_json"])
        self.assertEqual(summary["output_text_chars"], 2)
        self.assertEqual(summary["output_text_bytes"], 6)
        self.assertEqual(summary["output_count_source"], "terminal_output")
        self.assertEqual(summary["usage_objects"][0]["value"]["unknown"], {"future": True})
        chunks = db.execute("SELECT * FROM chunks ORDER BY seq").fetchall()
        self.assertEqual(b"".join(gzip.decompress(c["application_gzip"]) for c in chunks), body)
        self.assertEqual([c["seq"] for c in chunks], list(range(len(body))))
        self.assertTrue(all(c["utc_ns"] > 0 and c["mono_ns"] > 0 for c in chunks))

    def test_gzip_entity_replay(self):
        body = event(completed())
        encoded = gzip.compress(body)
        db, row = self.run_capture([encoded[:9], encoded[9:]], "gzip")
        self.assertEqual(row["state"], "complete")
        chunks = db.execute("SELECT * FROM chunks ORDER BY seq").fetchall()
        self.assertEqual(b"".join(gzip.decompress(c["entity_gzip"]) for c in chunks), encoded)
        self.assertEqual(b"".join(gzip.decompress(c["application_gzip"]) for c in chunks), body)

    def test_gzip_chunk_past_the_decode_limit_keeps_its_partial_output(self):
        encoded = gzip.compress(bytes(2 * DECODE_LIMIT))
        db, row = self.run_capture([encoded[:-8], encoded[-8:]], "gzip")
        self.assertIn("decode_error", json.loads(row["issues_json"]))
        self.assertIsNone(row["response_sha256"])
        chunks = db.execute("SELECT * FROM chunks ORDER BY seq").fetchall()
        self.assertEqual(b"".join(gzip.decompress(c["entity_gzip"]) for c in chunks), encoded)
        self.assertEqual(gzip.decompress(chunks[0]["application_gzip"]), bytes(DECODE_LIMIT + 1))
        self.assertIsNone(chunks[1]["application_gzip"])

    def test_identity_chunk_past_the_decode_limit_keeps_its_output_and_decodes_nothing_after(self):
        db, row = self.run_capture([bytes(DECODE_LIMIT + 1), b"after"], "identity")
        self.assertIn("decode_error", json.loads(row["issues_json"]))
        self.assertIsNone(row["response_sha256"])
        chunks = db.execute("SELECT * FROM chunks ORDER BY seq").fetchall()
        self.assertEqual(gzip.decompress(chunks[0]["application_gzip"]), bytes(DECODE_LIMIT + 1))
        self.assertIsNone(chunks[1]["application_gzip"])

    def test_credit_envelope_in_sse_and_json_response(self):
        writer = Collector(self.path)
        ids = []
        obj = completed()
        response = dict(obj["response"], object="response", status="completed")
        for content_type, payload in (("text/event-stream", event(obj)),
                                      ("application/json", json.dumps(response).encode())):
            ident = writer.begin({}, b"{}")
            ids.append(ident)
            writer.headers(ident, {"content_type": content_type})
            writer.chunk(ident, payload)
            writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            for ident in ids:
                state, issues, credits, context, summary = db.execute("SELECT state,issues_json,credits,context_usage_percentage,summary_json FROM captures WHERE id=?", (ident,)).fetchone()
                self.assertEqual((state, json.loads(issues), credits, context), ("complete", [], .25, 12.3))
                usage = json.loads(summary)["usage_objects"][0]["value"]
                self.assertEqual(usage, obj["response"]["usage"])

    def test_rpc_generate_assistant_response_decodes_event_stream_whatever_its_content_type(self):
        writer = Collector(self.path)
        ident = writer.begin({"host": "runtime.kiro.dev", "path": "/", "target": "KiroRuntimeService.GenerateAssistantResponse"},
                             b'{"conversationState":{"conversationId":"sess_rpc","currentMessage":{}}}')
        writer.headers(ident, {"content_type": "application/json", "content_encoding": "identity"})
        writer.chunk(ident, aws_event("meteringEvent", {"usage": .5, "unit": "credit"}))
        writer.finish(ident)
        writer.close()
        db = sqlite3.connect(self.path)
        self.addCleanup(db.close)
        self.assertEqual(db.execute("SELECT state,credits FROM captures WHERE id=?", (ident,)).fetchone(), ("complete", .5))

    def test_event_stream_split_messages_usage_and_completion(self):
        # Bool (type 0) and UUID (type 9) headers are skipped without losing the string headers.
        skipped = b"\x04flag\x00" + b"\x02id\x09" + bytes(16)
        messages = [aws_event("assistantResponseEvent", {"content": "é🙂"}, extra=skipped),
                    aws_event("toolUseEvent", {"toolUseId": "t", "name": "n", "input": "{}"}),
                    aws_event("contextUsageEvent", {"contextUsagePercentage": 12.3}),
                    aws_event("metadataEvent", {"tokenUsage": {"uncachedInputTokens": 10, "cacheReadInputTokens": 80, "cacheWriteInputTokens": 5, "outputTokens": 4, "totalTokens": 99}, "stopReason": "END_TURN"}),
                    aws_event("meteringEvent", {"usage": .25, "unit": "credit", "unitPlural": "credits"})]
        body = b"".join(messages)
        db, row = self.run_capture([body[i:i+1] for i in range(len(body))], content_type=EVENTSTREAM)
        self.assertEqual((row["state"], row["completion_seen"], json.loads(row["issues_json"])), ("complete", 1, []))
        self.assertEqual(row["response_sha256"], digest(body))
        self.assertEqual((row["credits"], row["context_usage_percentage"]), (.25, 12.3))
        self.assertEqual((row["input_tokens"], row["output_tokens"], row["cache_read_tokens"], row["cache_write_tokens"]), (95, 4, 80, 5))
        summary = json.loads(row["summary_json"])
        self.assertEqual((summary["output_text_chars"], summary["output_text_bytes"], summary["terminal"]), (2, 6, "END_TURN"))
        self.assertEqual(summary["usage_objects"][0], {"path": "/tokenUsage", "value": json.loads(messages[3][messages[3].index(b"{"):-4])["tokenUsage"]})
        events = db.execute("SELECT event_name,frame_gzip,data_json FROM events ORDER BY seq").fetchall()
        self.assertEqual([e["event_name"] for e in events], ["assistantResponseEvent", "toolUseEvent", "contextUsageEvent", "metadataEvent", "meteringEvent"])
        self.assertEqual([gzip.decompress(e["frame_gzip"]) for e in events], messages)
        self.assertEqual(json.loads(events[0]["data_json"]), {"content": "é🙂"})

    def test_event_stream_multiple_metering_events_keep_last_and_stay_complete(self):
        _, row = self.run_capture([aws_event("meteringEvent", {"usage": .25, "unit": "credit"}),
                                   aws_event("meteringEvent", {"usage": .5, "unit": "credit"})], content_type=EVENTSTREAM)
        self.assertEqual((row["state"], json.loads(row["issues_json"]), row["credits"]), ("complete", [], .5))
        self.assertEqual(json.loads(row["summary_json"])["metering_events"], 2)

    def test_event_stream_absent_counters_stay_null(self):
        _, row = self.run_capture([aws_event("metadataEvent", {"tokenUsage": {"uncachedInputTokens": 7, "outputTokens": 3}})], content_type=EVENTSTREAM)
        self.assertEqual(row["state"], "complete")
        self.assertEqual(row["output_tokens"], 3)
        # Without both cache counters the cache-inclusive input total is unknown, never the uncached part alone.
        for column in ("input_tokens", "cache_read_tokens", "cache_write_tokens", "credits", "context_usage_percentage"):
            self.assertIsNone(row[column])
        self.assertIsNone(json.loads(row["summary_json"])["terminal"])
        _, row = self.run_capture([aws_event("metadataEvent", {"tokenUsage": {"uncachedInputTokens": 1, "cacheReadInputTokens": -1, "cacheWriteInputTokens": 0}}),
                                   aws_event("meteringEvent", {"usage": .5, "unit": "token"})], content_type=EVENTSTREAM)
        self.assertEqual((row["input_tokens"], row["cache_read_tokens"], row["credits"]), (None, None, None))
        self.assertEqual(json.loads(row["issues_json"]), ["invalid_credit_unit", "invalid_usage_number"])

    def test_event_stream_crc_mismatch_and_untrusted_prelude(self):
        metering = aws_event("meteringEvent", {"usage": .5, "unit": "credit"})
        db, row = self.run_capture([aws_event("assistantResponseEvent", {"content": "x"}, corrupt=1) + metering], content_type=EVENTSTREAM)
        self.assertEqual((row["state"], row["completion_seen"], row["credits"]), ("incomplete", 0, .5))  # the trusted length resynchronizes
        self.assertIn("event_stream_crc", json.loads(row["issues_json"]))
        self.assertIsNone(db.execute("SELECT data_json FROM events WHERE capture_id=? AND seq=0", (row["id"],)).fetchone()[0])
        broken = bytearray(metering)
        broken[8] ^= 1
        db, row = self.run_capture([bytes(broken) + metering], content_type=EVENTSTREAM)
        self.assertIn("event_stream_crc", json.loads(row["issues_json"]))
        self.assertIsNone(row["credits"])
        self.assertEqual([gzip.decompress(e[0]) for e in db.execute("SELECT frame_gzip FROM events WHERE capture_id=?", (row["id"],))], [bytes(broken[:12])])

    def test_event_stream_exception_unterminated_and_empty_are_incomplete(self):
        exception = aws_message({":message-type": "exception", ":exception-type": "ThrottlingException", ":content-type": "application/json"}, b'{"message":"synthetic"}')
        metering = aws_event("meteringEvent", {"usage": .5, "unit": "credit"})
        for parts, issue in (([metering, exception], "missing_completion"), ([metering + metering[:5]], "unterminated_event"), ([], "missing_completion")):
            db, row = self.run_capture(parts, content_type=EVENTSTREAM)
            self.assertEqual((row["state"], row["completion_seen"]), ("incomplete", 0))
            self.assertIn(issue, json.loads(row["issues_json"]))
        db, row = self.run_capture([metering, exception], content_type=EVENTSTREAM)
        self.assertEqual(json.loads(row["summary_json"])["terminal"], "exception")
        metadata = aws_event("metadataEvent", {"stopReason": "END_TURN"})
        db, row = self.run_capture([metering, exception, metadata], content_type=EVENTSTREAM)
        self.assertEqual(json.loads(row["summary_json"])["terminal"], "exception")  # a later stopReason does not hide it
        self.assertEqual(tuple(db.execute("SELECT event_name,data_json FROM events WHERE capture_id=? AND seq=1", (row["id"],)).fetchone()), ("ThrottlingException", '{"message":"synthetic"}'))

    def test_event_stream_size_limit_and_invalid_headers(self):
        frames = []
        parser = EventStream(lambda *args: frames.append(args), limit=64)
        parser.feed(aws_event("assistantResponseEvent", {"content": "x" * 64}))
        self.assertTrue(parser.disabled)
        self.assertEqual(frames, [])
        truncated = aws_message({}, extra=b"\x04name\x07\x00\x09short")
        unknown = aws_message({}, extra=b"\x04name\x0b")
        parser = EventStream(lambda *args: frames.append(args))
        parser.feed(truncated + unknown)
        self.assertEqual([(frame, problem) for frame, _, _, problem in frames], [(truncated, "invalid_event_frame"), (unknown, "invalid_event_frame")])

    def test_multiline_sse_mixed_line_endings(self):
        frames = []
        parser = SSE(lambda *args: frames.append(args))
        body = b':comment\r\nevent: custom\rdata: {"a":\r\ndata: 1}\n\n'
        for byte in body:
            parser.feed(bytes([byte]))
        parser.feed(b"", final=True)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][0], body)
        self.assertFalse(frames[0][2])

    def test_missing_completion_and_shutdown(self):
        _, row = self.run_capture([event({"type": "response.output_text.delta", "delta": "hello"})], finish=False)
        self.assertEqual(row["state"], "incomplete")
        self.assertIn("collector_shutdown", json.loads(row["issues_json"]))
        self.assertEqual(json.loads(row["summary_json"])["output_text_chars"], 5)

    def test_error_and_absent_usage(self):
        _, row = self.run_capture([event({"type": "error", "error": {"code": "synthetic"}})])
        self.assertEqual(json.loads(row["summary_json"])["terminal"], "error")
        self.assertIsNone(row["credits"])
        self.assertEqual(row["state"], "incomplete")

    def test_unknown_encoding_retains_entity(self):
        db, row = self.run_capture([b"opaque"], "unknown")
        self.assertIn("unsupported_content_encoding", json.loads(row["issues_json"]))
        self.assertIsNone(row["response_sha256"])
        chunk = db.execute("SELECT * FROM chunks").fetchone()
        self.assertEqual(gzip.decompress(chunk["entity_gzip"]), b"opaque")
        self.assertIsNone(chunk["application_gzip"])

    def test_partial_event_not_dispatched(self):
        db, row = self.run_capture([event(completed())[:-1]])
        self.assertFalse(row["completion_seen"])
        self.assertIn("unterminated_event", json.loads(row["issues_json"]))
        self.assertIsNone(db.execute("SELECT data_json FROM events").fetchone()[0])

    def test_slow_commits_batch_a_long_stream_without_loss(self):
        parts = chatty()
        SlowCommits.commits = 0
        with patch("capture.sqlite3.connect", functools.partial(sqlite3.connect, factory=SlowCommits)):
            db, row = self.run_capture(parts)
        self.assertEqual((row["state"], json.loads(row["issues_json"]), row["dropped_chunks"]), ("complete", [], 0))
        self.assertEqual((row["credits"], row["context_usage_percentage"]), (.25, 12.3))
        self.assertEqual(db.execute("SELECT count(*) FROM chunks").fetchone()[0], len(parts))
        self.assertLess(SlowCommits.commits, len(parts) // 10)  # one request and 501 chunk items

    def test_refused_payloads_keep_usage_complete(self):
        parts = chatty()
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            db, row = self.run_capture(parts, max_bytes=1)
        self.assertIn("response payload omitted, usage still parsed", stderr.getvalue())
        self.assertEqual((row["state"], json.loads(row["issues_json"])), ("complete", ["request_payload_omitted", "response_payload_omitted"]))
        self.assertEqual((row["credits"], row["context_usage_percentage"], row["completion_seen"]), (.25, 12.3, 1))
        self.assertEqual(json.loads(row["summary_json"])["output_text_chars"], 2)
        self.assertEqual(row["response_sha256"], digest(b"".join(parts)))
        self.assertEqual((row["dropped_chunks"], row["observed_chunks"]), (len(parts) + 1, len(parts)))
        self.assertEqual(json.loads(row["metadata_json"])["kiro:conversation_id"], "sess_fake")
        self.assertIsNone(row["request_gzip"])
        self.assertEqual(db.execute("SELECT count(*) FROM chunks").fetchone()[0], 0)
        replay = subprocess.run([sys.executable, str(Path(__file__).with_name("capture.py")), "--db", str(self.path), "replay", row["id"]], capture_output=True)
        self.assertEqual((replay.returncode, replay.stdout), (1, b""))

    def test_refused_payloads_keep_delta_counts(self):
        # No terminal output list: every count comes from deltas the queue never stored.
        deltas = [event({"type": kind, "delta": "x" * size}) for kind, size in (
            ("response.output_text.delta", 5), ("response.function_call_arguments.delta", 7), ("response.reasoning_text.delta", 3))] * 50
        terminal = {"type": "response.completed", "response": {"usage": {"kiro:credits": {"unit": "credit", "value": .25}}}}
        with contextlib.redirect_stderr(io.StringIO()):
            db, row = self.run_capture([*deltas, event(terminal)], max_bytes=1)
        self.assertEqual(row["state"], "complete")
        self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 0)
        summary = json.loads(row["summary_json"])
        self.assertEqual((summary["output_count_source"], summary["output_text_chars"]), ("deltas", 250))
        self.assertEqual((summary["tool_chars"], summary["reasoning_chars"]), (350, 150))

    def test_live_tool_and_reasoning_counts_take_deltas_over_terminal_once(self):
        output = [{"type": "function_call", "arguments": "x" * 40}, {"type": "reasoning", "content": [{"type": "reasoning_text", "text": "y" * 20}]}]
        final = {"type": "response.completed", "response": {"output": output}}
        delta = event({"type": "response.function_call_arguments.delta", "delta": "x" * 40})
        _, row = self.run_capture([delta, event(final), event(final)])  # a repeated terminal event is the same output
        summary = json.loads(row["summary_json"])
        self.assertEqual((summary["tool_chars"], summary["reasoning_chars"]), (40, 20))
        self.path = self.path.with_name("generate.sqlite3")
        parts = [aws_event("toolUseEvent", {"input": "z" * 16, "name": "shell"}), aws_event("reasoningContentEvent", {"text": "w" * 4})]
        _, row = self.run_capture(parts, content_type=EVENTSTREAM)
        summary = json.loads(row["summary_json"])
        self.assertEqual((summary["tool_chars"], summary["reasoning_chars"]), (16, 4))

    def test_event_copies_are_staged_only_within_the_queue_budget(self):
        writer = Collector(self.path, max_bytes=64 * 1024)
        staged, original = [], writer._stage
        def stage(target, *saved):
            original(target, *saved)
            staged.append(len(target["events"]))
        with patch.object(writer, "_stage", side_effect=stage), contextlib.redirect_stderr(io.StringIO()):
            ident = writer.begin({}, b"{}")
            writer.headers(ident, {"content_type": "text/event-stream"})
            writer.chunk(ident, b"\n\n" * 20000 + event(completed()))
            writer.finish(ident)
            writer.close()
        self.assertEqual(len(staged), 40001)  # analysis saw every frame
        self.assertLessEqual(max(staged), 64 * 1024 // Collector.OVERHEAD)
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            row = db.execute("SELECT state,credits,issues_json FROM captures").fetchone()
        self.assertEqual(row, ("complete", .25, '["response_payload_omitted"]'))

    def test_batches_respect_the_byte_bound_and_carry_the_overflow(self):
        writer = Collector(self.path)
        writer.close()  # its worker is done; drive _batch by hand
        sizes = [3 << 20, 3 << 20, 32 << 20, 1, 1]
        for size in sizes:
            writer.queue.put((size, size))
        batches = [[item[-1] for item in batch] for batch in iter(writer._batch, [])]
        self.assertEqual(batches, [[3 << 20], [3 << 20], [32 << 20], [1, 1]])

    def test_replay_refuses_a_chunk_gap(self):
        parts = [event({"type": "response.output_text.delta", "delta": "a"}), event({"type": "response.output_text.delta", "delta": "b"}), event(completed())]
        db, row = self.run_capture(parts)
        db.execute("DELETE FROM chunks WHERE seq=1")
        db.commit()
        replay = subprocess.run([sys.executable, str(Path(__file__).with_name("capture.py")), "--db", str(self.path), "replay", row["id"]], capture_output=True)
        self.assertEqual((replay.returncode, replay.stdout), (1, parts[0]))

    def test_request_at_the_api_limit_is_retained(self):
        body = b'{"input":"' + b"x" * (32 * 1024 * 1024 - 12) + b'"}'
        writer = Collector(self.path)
        ident = writer.begin({}, body)
        writer.headers(ident, {"content_type": "text/event-stream"})
        writer.chunk(ident, event(completed()))
        writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            state, issues, request = db.execute("SELECT state,issues_json,request_gzip FROM captures").fetchone()
        self.assertEqual((len(body), state, issues), (32 * 1024 * 1024, "complete", "[]"))
        self.assertEqual(gzip.decompress(request), body)

    def test_tiny_chunks_are_charged_their_object_overhead(self):
        writer = Collector(self.path, max_bytes=64 * 1024)
        release = threading.Event()
        original = writer._prepare
        def blocked(*args):
            self.assertTrue(release.wait(2))
            return original(*args)
        with patch.object(writer, "_prepare", side_effect=blocked), contextlib.redirect_stderr(io.StringIO()):
            ident = writer.begin({}, b"{}")
            writer.headers(ident, {"content_type": "application/json"})
            for _ in range(1024):
                writer.chunk(ident, b" ")
            release.set()
            writer.finish(ident)
            writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            self.assertLessEqual(db.execute("SELECT count(*) FROM chunks").fetchone()[0], 64 * 1024 // 512)

    def test_commits_skip_fsync_under_wal(self):
        with contextlib.closing(open_database(self.path)) as db:
            self.assertEqual(db.execute("PRAGMA synchronous").fetchone()[0], 1)  # NORMAL

    def test_payload_warning_threshold_keeps_retaining(self):
        writer = Collector(self.path, warn_bytes=1)
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            for _ in range(2):
                ident = writer.begin({}, b"{}")
                writer.headers(ident, {"content_type": "text/event-stream"})
                writer.chunk(ident, event(completed()))
                writer.finish(ident)
            writer.close()
        self.assertEqual(stderr.getvalue().count("past the 1-byte warning"), 1)  # once per collector run
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            rows = db.execute("SELECT state,issues_json,dropped_bytes,credits,request_gzip IS NOT NULL FROM captures").fetchall()
            self.assertEqual(rows, [("complete", "[]", 0, .25, 1)] * 2)
            self.assertEqual(db.execute("SELECT count(*) FROM chunks WHERE entity_gzip IS NOT NULL").fetchone()[0], 2)

    def test_exact_counts_only_when_present(self):
        obj = completed()
        obj["response"]["usage"].update(input_tokens=12, output_tokens=4, input_tokens_details={"cached_tokens": 8})
        _, row = self.run_capture([event(obj)])
        self.assertEqual((row["input_tokens"], row["output_tokens"], row["cache_read_tokens"]), (12, 4, 8))
        self.assertIsNone(row["cache_write_tokens"])

    def test_fingerprints_and_metadata(self):
        body = b'{"model":"m","reasoning":{"effort":"high"},"input":[{"role":"system","content":"a"}],"metadata":{"kiro:conversation_id":"s","authorization":"omit"},"unknown":true}'
        meta, hashes = request_details(body)
        self.assertEqual(meta, {"model": "m", "effort": "high", "kiro:conversation_id": "s"})
        self.assertIn("input_items", hashes)
        self.assertNotIn("authorization", meta)
        self.assertNotIn("unknown", hashes)

    def test_generate_assistant_response_request_metadata(self):
        history = [{"userInputMessage": {"content": "a"}}, {"assistantResponseMessage": {"content": "b"}}]
        body = json.dumps({"conversationState": {"conversationId": "sess_step", "rootConversationId": "sess_root", "chatTriggerType": "MANUAL", "history": history,
                                                 "currentMessage": {"userInputMessage": {"content": "c", "modelId": "claude-opus-5.5", "userInputMessageContext": {"tools": [{"toolSpecification": {"name": "t"}}]}}}},
                           "additionalModelRequestFields": {"output_config": {"effort": "low"}}, "profileArn": "never"}).encode()
        meta, hashes = request_details(body, rpc=True)
        self.assertEqual(meta, {"model": "claude-opus-5.5", "effort": "low", "kiro:conversation_id": "sess_step", "kiro:root_conversation_id": "sess_root"})
        self.assertEqual(set(hashes), {"currentMessage", "history", "history_items", "prefixes", "tools"})
        self.assertEqual(hashes["history_items"], [digest(json.dumps(item, separators=(",", ":")).encode()) for item in history])
        self.assertEqual(request_details(b'{"conversationState":{},"additionalModelRequestFields":{"reasoning":{"effort":"high"}}}', rpc=True)[0], {"effort": "high"})
        # The selection, not the body shape, picks the parser: a conversationState body on CreateResponse stays CreateResponse.
        self.assertEqual(request_details(body)[0], {})
        self.assertEqual(request_details(b'{"model":"m"}', rpc=True)[0], {})

    def test_private_database_and_additional_tables(self):
        db = open_database(self.path)
        db.execute("CREATE TABLE disk_test (x)")
        db.close()
        writer = Collector(self.path)
        writer.close()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        os.chmod(self.path.parent, 0o755)
        with self.assertRaises(ValueError):
            open_database(self.path)

    def test_unusable_database_fails_at_start(self):
        self.path.parent.mkdir(mode=0o700, parents=True)
        self.path.write_bytes(b"not sqlite")
        os.chmod(self.path, 0o600)
        with self.assertRaises(sqlite3.DatabaseError):
            Collector(self.path)

    def test_cancelled_transport(self):
        writer = Collector(self.path)
        ident = writer.begin({}, b"{}")
        writer.finish(ident, transport_ended=False, error="transport_error")
        writer.close()
        db = sqlite3.connect(self.path)
        try:
            state, ended, issues = db.execute("SELECT state,transport_ended,issues_json FROM captures").fetchone()
            self.assertEqual((state, ended), ("incomplete", 0))
            self.assertIn("transport_error", json.loads(issues))
        finally:
            db.close()

    def test_writer_failure_surfaces(self):
        writer = Collector(self.path)
        with patch.object(writer, "_prepare", side_effect=sqlite3.OperationalError("synthetic disk error")):
            ident = writer.begin({}, b"{}")
            writer.chunk(ident, b"x")
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    writer.close()
        with self.assertRaises(RuntimeError):
            writer.check()

    def test_callback_does_not_wait_for_database(self):
        entered, release = threading.Event(), threading.Event()
        writer = Collector(self.path)
        original = writer._prepare
        def blocked(*args):
            entered.set()
            self.assertTrue(release.wait(2))
            return original(*args)
        with patch.object(writer, "_prepare", side_effect=blocked):
            ident = writer.begin({}, b"{}")
            writer.headers(ident, {"content_type": "text/event-stream"})
            writer.chunk(ident, b"x")
            self.assertTrue(entered.wait(2))
            before = time.monotonic()
            payload = b"y"
            self.assertIs(writer.chunk(ident, payload), payload)
            self.assertLess(time.monotonic() - before, .5)
            writer.finish(ident)
            release.set()
            writer.close()

    def test_restart_marks_interrupted_and_single_writer(self):
        writer = Collector(self.path)
        try:
            with self.assertRaises(BlockingIOError):
                Collector(self.path)
        finally:
            writer.close()
        db = sqlite3.connect(self.path)
        db.execute("INSERT INTO captures(id,state,metadata_json) VALUES('crashed','recording','{}')")
        db.commit()
        db.close()
        writer = Collector(self.path)
        writer.close()
        db = sqlite3.connect(self.path)
        try:
            row = db.execute("SELECT state,issues_json FROM captures WHERE id='crashed'").fetchone()
            self.assertEqual(row, ("incomplete", '["interrupted_capture"]'))
        finally:
            db.close()

    def test_nested_payloads_preserve_bytes_and_worker_recovers(self):
        nested = b"[" * 1200 + b"0" + b"]" * 1200
        writer = Collector(self.path)
        identifiers = []
        for request, response, content_type in ((nested, event(completed()), "text/event-stream"),
                                               (b"{}", b"data: " + nested + b"\n\n", "text/event-stream"),
                                               (b"{}", nested, "application/json"),
                                               (b"{}", event(completed()), "text/event-stream")):
            ident = writer.begin({}, request)
            identifiers.append(ident)
            writer.headers(ident, {"content_type": content_type})
            writer.chunk(ident, response)
            writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            rows = [db.execute("SELECT state,issues_json,request_gzip FROM captures WHERE id=?", (ident,)).fetchone() for ident in identifiers]
            self.assertEqual([row[0] for row in rows], ["incomplete"] * 3 + ["complete"])
            self.assertIn("invalid_request_json", rows[0][1])
            self.assertIn("invalid_event_data", rows[1][1])
            self.assertIn("invalid_json", rows[2][1])
            self.assertEqual(gzip.decompress(rows[0][2]), nested)

    def test_lone_surrogates_preserve_evidence_and_worker_recovers(self):
        request = json.dumps({"model": chr(0xD800)}).encode("ascii")
        bad_event = b"data: " + json.dumps({"type": "response.output_text.delta", "delta": "a", "x": chr(0xD800)}).encode("ascii") + b"\n\n"
        bad_key = json.dumps({chr(0xD800): "value"}).encode("ascii")
        writer = Collector(self.path)
        identifiers = []
        for body, response, content_type in ((request, event(completed()), "text/event-stream"),
                                              (b"{}", bad_event, "text/event-stream"),
                                              (b"{}", bad_key, "application/json"),
                                              (b"{}", event(completed()), "text/event-stream")):
            ident = writer.begin({}, body)
            identifiers.append(ident)
            writer.headers(ident, {"content_type": content_type})
            writer.chunk(ident, response)
            writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            rows = [db.execute("SELECT state,issues_json,request_gzip FROM captures WHERE id=?", (ident,)).fetchone() for ident in identifiers]
            self.assertEqual([row[0] for row in rows], ["incomplete"] * 3 + ["complete"])
            self.assertIn("invalid_request_json", rows[0][1])
            self.assertIn("invalid_event_data", rows[1][1])
            self.assertIn("invalid_json", rows[2][1])
            self.assertEqual(gzip.decompress(rows[0][2]), request)
            frame = db.execute("SELECT frame_gzip FROM events WHERE capture_id=?", (identifiers[1],)).fetchone()[0]
            self.assertEqual(gzip.decompress(frame), bad_event)

    def test_transient_writer_lock_longer_than_sqlite_default(self):
        writer = Collector(self.path)
        blocker = open_database(self.path)
        blocker.execute("BEGIN IMMEDIATE")
        try:
            ident = writer.begin({}, b"{}")
            writer.headers(ident, {"content_type": "text/event-stream"})
            payload = event(completed())
            before = time.monotonic()
            self.assertIs(writer.chunk(ident, payload), payload)
            self.assertLess(time.monotonic() - before, .5)
            writer.finish(ident)
            time.sleep(5.2)
            self.assertIsNone(writer.failure)
        finally:
            blocker.commit()
            blocker.close()
            writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            self.assertEqual(db.execute("SELECT state FROM captures WHERE id=?", (ident,)).fetchone()[0], "complete")

    def test_capture_failure_keeps_inflight_bytes_and_refuses_new_requests(self):
        addon = UsageCapture()
        with patch.dict(os.environ, {"KIRO_USAGE_DB": str(self.path)}):
            addon.load(None)
        request = SimpleNamespace(host="kiro.dev", path="/v1/responses", method="POST", headers={}, get_content=lambda strict: b"{}")
        flow = SimpleNamespace(id="failed", request=request, response=SimpleNamespace(status_code=200, headers={}))
        addon.request(flow)
        addon.responseheaders(flow)
        addon.collector.failure = RuntimeError("synthetic")
        with contextlib.redirect_stderr(io.StringIO()) as warnings:
            self.assertIs(flow.response.stream(b"first"), b"first")
            self.assertIs(flow.response.stream(b"second"), b"second")
            self.assertEqual(flow.response.stream(b""), b"")
            addon.response(flow)
            with patch.object(addon, "_reject") as reject:
                addon.request(SimpleNamespace(id="refused", request=request))
                reject.assert_called_once()
        self.assertEqual(warnings.getvalue().count("Kiro usage capture failed:"), 1)
        with self.assertRaises(RuntimeError):
            addon.done()

    def test_invalid_usage_numbers_do_not_stop_following_captures(self):
        writer = Collector(self.path)
        cases = [("input_tokens", 2**70), ("output_tokens", -1), ("input_tokens", True),
                 ("kiro:credits", 2**1024), ("kiro:context_usage_percentage", float("inf")),
                 ("kiro:credits", "invalid"), ("kiro:credits", None),
                 ("kiro:credits", True), ("kiro:credits", -1),
                 ("kiro:credits", float("nan")), ("kiro:credits", float("-inf")),
                 ("kiro:credits", 2**70)]
        ids = []
        for key, value in cases:
            obj = completed()
            if key == "kiro:credits":
                obj["response"]["usage"][key]["value"] = value
            else:
                obj["response"]["usage"][key] = value
            ident = writer.begin({}, b"{}")
            ids.append(ident)
            writer.headers(ident, {"content_type": "text/event-stream"})
            writer.chunk(ident, event(obj))
            writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            states = [db.execute("SELECT state,issues_json,credits FROM captures WHERE id=?", (ident,)).fetchone() for ident in ids]
            self.assertTrue(all(row[0] == "incomplete" and "invalid_usage_number" in row[1] for row in states[:-1]))
            for (key, _), row in zip(cases[:-1], states[:-1]):
                if key == "kiro:credits":
                    self.assertIsNone(row[2])
            self.assertEqual(states[-1][0], "complete")
            self.assertEqual(states[-1][2], float(2**70))

    def test_invalid_credit_envelopes_preserve_evidence_and_worker_recovers(self):
        cases = [(value, "invalid_credit_unit") for value in
                 (None, .25, [], {}, {"value": .25}, {"unit": "token", "value": .25})]
        cases += [({"unit": "credit"}, "invalid_usage_number"),
                  ({"unit": "credit", "value": float("inf")}, "invalid_usage_number"),
                  (completed()["response"]["usage"]["kiro:credits"], None)]
        writer = Collector(self.path)
        ids = []
        for envelope, _ in cases:
            obj = completed()
            obj["response"]["usage"]["kiro:credits"] = envelope
            ident = writer.begin({}, b"{}")
            ids.append(ident)
            writer.headers(ident, {"content_type": "text/event-stream"})
            writer.chunk(ident, event(obj))
            writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            for ident, (envelope, issue) in zip(ids, cases):
                state, issues, credits, summary = db.execute("SELECT state,issues_json,credits,summary_json FROM captures WHERE id=?", (ident,)).fetchone()
                self.assertEqual(state, "incomplete" if issue else "complete")
                self.assertEqual(json.loads(issues), [issue] if issue else [])
                self.assertEqual(credits, None if issue else .25)
                self.assertEqual(json.loads(summary)["usage_objects"][0]["value"]["kiro:credits"], envelope)

    def test_omitted_request_payload_alone_keeps_usage_complete(self):
        writer = Collector(self.path, max_bytes=4096)
        with contextlib.redirect_stderr(io.StringIO()):
            ident = writer.begin({}, b'{"metadata":{"kiro:conversation_id":"session"},"padding":"' + b"x" * 8192 + b'"}')
        writer.headers(ident, {"content_type": "text/event-stream"})
        payload = event(completed())
        writer.chunk(ident, payload)
        writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            row = db.execute("SELECT state,credits,response_sha256,request_gzip,fingerprints_json,issues_json,dropped_chunks FROM captures").fetchone()
            self.assertEqual(row[:4], ("complete", .25, digest(payload), None))
            self.assertIsNotNone(row[4])
            self.assertEqual(row[5:], ('["request_payload_omitted"]', 1))
            self.assertIsNotNone(db.execute("SELECT entity_gzip FROM chunks").fetchone()[0])

    def test_recoverable_request_refusals_leave_addon_healthy(self):
        addon = UsageCapture()
        with patch.dict(os.environ, {"KIRO_USAGE_DB": str(self.path)}):
            addon.load(None)
        self.addCleanup(addon.done)
        request = SimpleNamespace(host="kiro.dev", path="/v1/responses", method="POST", headers={}, get_content=lambda strict: b"{}")
        flow = SimpleNamespace(id="healthy", request=request, response=SimpleNamespace(status_code=200, headers={"content-type": "text/event-stream"}))
        with patch.object(addon, "_reject") as reject:
            with patch.object(request, "get_content", side_effect=ValueError("synthetic decoding error")):
                addon.request(flow)
                self.assertEqual(reject.call_args.kwargs["status"], 400)
            class Full(dict):
                def __len__(self):
                    return 256
            with patch.object(addon.collector, "states", Full()):
                addon.request(flow)
                self.assertEqual(reject.call_count, 2)
        self.assertFalse(addon.failed)
        addon.request(flow)
        addon.responseheaders(flow)
        payload = event(completed())
        self.assertIs(flow.response.stream(payload), payload)
        addon.response(flow)

    def test_payload_budget_accounting_is_identical_after_restart(self):
        writer = Collector(self.path)
        ident = writer.begin({}, b"{}")
        writer.headers(ident, {"content_type": "text/event-stream"})
        writer.chunk(ident, event(completed()))
        writer.finish(ident)
        writer.close()
        retained = writer.stored_bytes
        restarted = Collector(self.path)
        self.assertEqual(restarted.stored_bytes, retained)
        restarted.close()

    def test_startup_failure_keeps_addon_installed_and_refuses_selected_requests(self):
        addon = UsageCapture()
        with patch.dict(os.environ, {"KIRO_USAGE_DB": str(self.path)}), patch("mitm_addon.Collector", side_effect=OSError("synthetic startup error")):
            with contextlib.redirect_stderr(io.StringIO()) as warnings:
                addon.load(None)
        self.assertIn("capture startup failed", warnings.getvalue())
        self.assertFalse(self.path.exists())
        selected = SimpleNamespace(request=SimpleNamespace(host="kiro.dev", path="/v1/responses"))
        excluded = SimpleNamespace(request=SimpleNamespace(host="example.invalid", path="/v1/responses"))
        with patch.object(addon, "_reject") as reject:
            addon.request(excluded)
            reject.assert_not_called()
            addon.request(selected)
            reject.assert_called_once_with(selected)
        self.assertTrue(addon.failed)
        self.assertIsNone(addon.collector)
        addon.done()

    def test_offline_list_human_and_original_json_lines(self):
        command = [sys.executable, str(Path(__file__).with_name("capture.py")), "--db", str(self.path), "list"]
        Collector(self.path).close()
        # Empty lists still have readable column headers.
        empty = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertIn("Capture", empty.stdout)
        _, row = self.run_capture([event(completed())])
        human = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertIn(row["id"], human.stdout)
        self.assertIn("complete", human.stdout)
        self.assertRegex(human.stdout, r"complete\s+\d+\s+0\s+0.25\s+12.3")
        structured = subprocess.run([*command, "--json"], capture_output=True, text=True, check=True)
        self.assertEqual(structured.stderr, "")
        listed = [json.loads(line) for line in structured.stdout.splitlines()]
        self.assertEqual(listed, [{key: row[key] for key in
                                  ("id", "state", "observed_bytes", "dropped_bytes", "credits", "context_usage_percentage", "issues_json")}])

    def test_offline_replay_cli(self):
        body = event(completed())
        _, row = self.run_capture([body])
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("capture.py")), "--db", str(self.path), "replay", row["id"]], capture_output=True, check=True)
        self.assertEqual(result.stdout, body)

    def test_addon_boundary_privacy_and_immediate_pass_through(self):
        addon = UsageCapture()
        with patch.dict(os.environ, {"KIRO_USAGE_DB": str(self.path)}):
            addon.load(None)
        self.addCleanup(addon.done)
        def flow(host="runtime.kiro.dev", path="/v1/responses?secret=never", ident="selected", target=None, body=b'{"model":"fake"}', method="POST"):
            headers = {"authorization": "never", "cookie": "never", **({"x-amz-target": target} if target else {})}
            return SimpleNamespace(id=ident, request=SimpleNamespace(host=host, path=path, method=method, headers=headers, get_content=lambda strict: body), response=SimpleNamespace(headers={"content-type": "text/event-stream", "x-amzn-requestid": "upstream-fake", "set-cookie": "never"}, status_code=200, stream=None))
        generate = "KiroRuntimeService.GenerateAssistantResponse"
        # The schema's REST path is never sent; RPC selection is the exact target on POST / only.
        for host, path, target in (("not-kiro.dev", "/v1/responses", None), ("kiro.dev.evil", "/v1/responses", None), ("kiro.dev", "/other", None), ("kiro.dev", "/generateAssistantResponse", None),
                                   ("kiro.dev", "/", None), ("kiro.dev", "/", "KiroRuntimeService.GetUsageLimits"), ("kiro.dev", "/", generate + "X"), ("kiro.dev", "/v1/responses/", generate), ("not-kiro.dev", "/", generate)):
            rejected = flow(host, path, f"{host}{path}{target}", target)
            addon.request(rejected)
            self.assertNotIn(rejected.id, addon.active)
        for method in ("GET", "OPTIONS"):  # RPC calls are POST; the target alone does not select
            rejected = flow("kiro.dev", "/", f"rpc-{method}", generate, method=method)
            addon.request(rejected)
            self.assertNotIn(rejected.id, addon.active)
        selected = flow()
        addon.request(selected)
        addon.responseheaders(selected)
        data = event(completed())
        self.assertIs(selected.response.stream(data), data)
        self.assertEqual(selected.response.stream(b""), b"")
        addon.response(selected)
        request = json.dumps({"conversationState": {"conversationId": "sess_step", "currentMessage": {"userInputMessage": {"modelId": "m"}}}}).encode()
        step = flow(path="/?secret=never", ident="step", target=generate, body=request)
        step.response.headers["content-type"] = EVENTSTREAM
        addon.request(step)
        addon.responseheaders(step)
        data = aws_event("meteringEvent", {"usage": .5, "unit": "credit"})
        self.assertIs(step.response.stream(data), data)
        addon.response(step)
        addon.done()
        db = sqlite3.connect(self.path)
        try:
            rows = db.execute("SELECT metadata_json,response_json,state,credits FROM captures ORDER BY json_extract(metadata_json,'$.path') DESC").fetchall()
            for metadata, response, _, _ in rows:
                self.assertNotIn("never", metadata + response)
                self.assertIn("upstream-fake", response)
            self.assertEqual([json.loads(row[0]) for row in rows], [{"host": "runtime.kiro.dev", "method": "POST", "path": "/v1/responses", "model": "fake", "request_content_encoding": "identity"},
                                                                    {"host": "runtime.kiro.dev", "method": "POST", "path": "/", "target": generate, "model": "m", "kiro:conversation_id": "sess_step", "request_content_encoding": "identity"}])
            self.assertEqual(rows[1][2:], ("complete", .5))
        finally:
            db.close()


class RuntimeTests(unittest.TestCase):
    def test_exec_environment_and_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state with spaces"
            runtime.private_directory(state, create=True)
            runtime.private_directory(state / "ca", create=True)
            (state / "ca/mitmproxy-ca-cert.pem").write_text("fake CA")
            inherited = {"PATH": "/project/bin", "KEEP": "yes", **{name: "conflict" for name in runtime.PROXY_NAMES}}
            with patch.dict(os.environ, inherited, clear=True), patch.object(runtime.socket, "create_connection") as connect, patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "refresh_disk_index", return_value=False), patch.object(runtime, "invocation_summary"):
                with self.assertRaisesRegex(ValueError, "inherited ALL_PROXY conflicts"):
                    runtime.launch_environment(state, 19001)
                runtime.exec_command(state, 19001, 1 << 30, ["--", "kiro-cli", "chat", "spaced argument", "--", "--agent-engine=v2"])
                command, arguments, environment = wait.call_args.args
                self.assertEqual(command, "kiro-cli")
                self.assertEqual(arguments, ["--v3", "chat", "spaced argument", "--", "--agent-engine=v2"])
                self.assertEqual(environment["KEEP"], "yes")
                self.assertEqual(environment["PATH"], "/project/bin")
                for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
                    self.assertEqual(environment[name], f"http://kiro-usage-{environment['KIRO_USAGE_INVOCATION']}:@127.0.0.1:19001")
                self.assertEqual(environment["NODE_EXTRA_CA_CERTS"], str(state / "ca/mitmproxy-ca-cert.pem"))
                for name in ("ALL_PROXY", "NO_PROXY", "all_proxy", "no_proxy"):
                    self.assertNotIn(name, environment)
                self.assertEqual(os.environ["NO_PROXY"], "conflict")
                connect.assert_called_with(("127.0.0.1", 19001), timeout=0.5)
                for arguments in (["kiro-cli", "--agent-engine=v2"], ["kiro-cli-chat"]):
                    with self.assertRaisesRegex(ValueError, "v3"):
                        runtime.exec_command(state, 19001, 1 << 30, arguments)
                runtime.exec_command(state, 19001, 1 << 30, ["kiro-cli", "--v3"])
                self.assertEqual(wait.call_args.args[1], ["--v3"])
                execute.side_effect = FileNotFoundError()
                with self.assertRaisesRegex(runtime.CommandError, "command not found: absent"):
                    runtime.exec_command(state, 19001, 1 << 30, ["absent"])
                for error in (FileNotFoundError(), PermissionError(13, "Permission denied")):
                    execute.side_effect = error
                    output = io.StringIO()
                    with patch.object(sys, "argv", ["runtime.py", "cli", "--state-dir", str(state), "--port", "19001", "--warn-bytes", "1", "--", "exec", "absent"]), contextlib.redirect_stderr(output):
                        self.assertEqual(runtime.main(), 1)
                    self.assertIn("absent", output.getvalue())
                    self.assertNotIn("Start the kiro-usage service", output.getvalue())
        with self.assertRaisesRegex(ValueError, "COMMAND"):
            runtime.exec_command(Path("/unused"), 19001, 1 << 30, [])

    def test_exec_exit_and_signal(self):
        # Replacement must preserve child exit codes and signals without a
        # supervising process translating them. Only this synthetic child runs.
        for code, expected in (("raise SystemExit(23)", 23), ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -15)):
            script = f"import runtime; from pathlib import Path; runtime.launch_environment = lambda *a, **kw: dict(runtime.os.environ); runtime.exec_command(Path('/unused'), 19001, 1 << 30, [{sys.executable!r}, '-c', {code!r}])"
            result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent)
            self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()

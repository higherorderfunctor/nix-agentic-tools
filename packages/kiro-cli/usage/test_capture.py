"""Synthetic offline contracts; no mitmproxy dependency, CLI launches or real data."""

import contextlib
import gzip
import io
import json
import os
from pathlib import Path
import runtime
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from capture import Collector, SSE, digest, open_database, request_details
from mitm_addon import UsageCapture


def event(obj, newline=b"\n"):
    return b"data: " + json.dumps(obj, ensure_ascii=False).encode() + newline + newline


def completed(text="é🙂"):
    return {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}, {"type": "reasoning", "summary": [{"text": "private reasoning"}]}, {"type": "function_call", "arguments": "{}"}], "usage": {"kiro:credits": {"unit": "credit", "unit_plural": "credits", "value": 0.25}, "kiro:context_usage_percentage": 12.3, "unknown": {"future": True}}}}


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "private" / "capture.sqlite3"

    def run_capture(self, parts, encoding="identity", finish=True, **options):
        writer = Collector(self.path, **options)
        ident = writer.begin({"host": "runtime.kiro.dev"}, b'{"model":"synthetic","metadata":{"kiro:conversation_id":"sess_fake"},"tools":[]}')
        writer.headers(ident, {"content_type": "text/event-stream", "content_encoding": encoding})
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
        db, row = self.run_capture([body[i:i+1] for i in range(len(body))], max_items=4096)
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

    def test_queue_overflow_is_explicit(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            _, row = self.run_capture([b"x" * 1024], max_bytes=128)
        self.assertIn("queue overflow", stderr.getvalue())
        self.assertGreater(row["dropped_bytes"], 0)
        self.assertIn("queue_overflow", json.loads(row["issues_json"]))
        self.assertEqual(row["state"], "incomplete")

    def test_storage_budget_stops_payload_retention(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            db, row = self.run_capture([event(completed())], max_stored_bytes=1)
        self.assertIn("storage budget", stderr.getvalue())
        self.assertIsNone(row["request_gzip"])
        self.assertIsNone(db.execute("SELECT entity_gzip FROM chunks").fetchone()[0])
        self.assertGreater(row["dropped_bytes"], 0)
        self.assertEqual(row["credits"], .25)  # observations remain useful
        self.assertEqual(row["state"], "incomplete")

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
        with patch.object(writer, "_store_chunk", side_effect=sqlite3.OperationalError("synthetic disk error")):
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
        original = writer._store_chunk
        def blocked(*args):
            entered.set()
            self.assertTrue(release.wait(2))
            return original(*args)
        with patch.object(writer, "_store_chunk", side_effect=blocked):
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

    def test_request_metadata_survives_payload_queue_refusal(self):
        with contextlib.redirect_stderr(io.StringIO()):
            _, row = self.run_capture([event(completed())], max_bytes=1)
        self.assertEqual(json.loads(row["metadata_json"])["kiro:conversation_id"], "sess_fake")
        self.assertIsNone(row["request_gzip"])

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

    def test_lost_request_does_not_disable_complete_response_analysis(self):
        writer = Collector(self.path, max_bytes=512)
        with contextlib.redirect_stderr(io.StringIO()):
            ident = writer.begin({}, b'{"metadata":{"kiro:conversation_id":"session"},"padding":"' + b"x" * 1024 + b'"}')
        writer.headers(ident, {"content_type": "text/event-stream"})
        payload = event(completed())
        writer.chunk(ident, payload)
        writer.finish(ident)
        writer.close()
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            row = db.execute("SELECT state,credits,response_sha256,request_gzip,fingerprints_json FROM captures").fetchone()
            self.assertEqual(row[:4], ("incomplete", .25, digest(payload), None))
            self.assertIsNotNone(row[4])

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
        def flow(host="runtime.kiro.dev", path="/v1/responses?secret=never", ident="selected"):
            return SimpleNamespace(id=ident, request=SimpleNamespace(host=host, path=path, method="POST", headers={"authorization": "never", "cookie": "never"}, get_content=lambda strict: b'{"model":"fake"}'), response=SimpleNamespace(headers={"content-type": "text/event-stream", "x-amzn-requestid": "upstream-fake", "set-cookie": "never"}, status_code=200, stream=None))
        for host, path in (("not-kiro.dev", "/v1/responses"), ("kiro.dev.evil", "/v1/responses"), ("kiro.dev", "/other")):
            rejected = flow(host, path, host + path)
            addon.request(rejected)
            self.assertNotIn(rejected.id, addon.active)
        selected = flow()
        addon.request(selected)
        addon.responseheaders(selected)
        data = event(completed())
        self.assertIs(selected.response.stream(data), data)
        self.assertEqual(selected.response.stream(b""), b"")
        addon.response(selected)
        addon.done()
        db = sqlite3.connect(self.path)
        try:
            metadata, response = db.execute("SELECT metadata_json,response_json FROM captures").fetchone()
            self.assertNotIn("never", metadata + response)
            self.assertIn("upstream-fake", response)
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
            with patch.dict(os.environ, inherited, clear=True), patch.object(runtime.socket, "create_connection") as connect, patch.object(os, "execvpe") as execute, patch.object(runtime, "wait_command", return_value=0) as wait, patch.object(runtime, "invocation_summary"):
                with self.assertRaisesRegex(ValueError, "inherited ALL_PROXY conflicts"):
                    runtime.launch_environment(state, 19001)
                runtime.exec_command(state, 19001, ["--", "kiro-cli", "chat", "spaced argument", "--", "--agent-engine=v2"])
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
                        runtime.exec_command(state, 19001, arguments)
                runtime.exec_command(state, 19001, ["kiro-cli", "--v3"])
                self.assertEqual(wait.call_args.args[1], ["--v3"])
                execute.side_effect = FileNotFoundError()
                with self.assertRaisesRegex(runtime.CommandError, "command not found: absent"):
                    runtime.exec_command(state, 19001, ["absent"])
                for error in (FileNotFoundError(), PermissionError(13, "Permission denied")):
                    execute.side_effect = error
                    output = io.StringIO()
                    with patch.object(sys, "argv", ["runtime.py", "cli", "--state-dir", str(state), "--port", "19001", "--", "exec", "absent"]), contextlib.redirect_stderr(output):
                        self.assertEqual(runtime.main(), 1)
                    self.assertIn("absent", output.getvalue())
                    self.assertNotIn("Start the kiro-usage service", output.getvalue())
        with self.assertRaisesRegex(ValueError, "COMMAND"):
            runtime.exec_command(Path("/unused"), 19001, [])

    def test_exec_exit_and_signal(self):
        # Replacement must preserve child exit codes and signals without a
        # supervising process translating them. Only this synthetic child runs.
        for code, expected in (("raise SystemExit(23)", 23), ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -15)):
            script = f"import runtime; from pathlib import Path; runtime.launch_environment = lambda *a, **kw: dict(runtime.os.environ); runtime.exec_command(Path('/unused'), 19001, [{sys.executable!r}, '-c', {code!r}])"
            result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).parent)
            self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()

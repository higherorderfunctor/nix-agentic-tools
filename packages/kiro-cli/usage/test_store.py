"""Synthetic staged and sealed capture stores; readers, seal, base chains and payload accounting."""

from contextlib import closing, contextmanager, redirect_stderr
import gzip
import io
import json
from pathlib import Path
import queue
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import calibration
import capture
import codec
from codec import Chunk, Event
from mitm_addon import GENERATE
import query
import report
import store
from test_capture import EVENTSTREAM, aws_event, completed, event
from test_codec import split, staged

SSE = {"content_type": "text/event-stream"}
DELTA = event({"type": "response.output_text.delta", "delta": "a"})


class StoreTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "usage.sqlite3"
        self.db = self.connect()
        self.db.executescript(capture.SCHEMA)
        self.db.execute("INSERT INTO capture_meta VALUES (2)")
        self.db.commit()

    def connect(self):
        db = capture.open_database(self.path)
        self.addCleanup(db.close)
        return db

    def stage(self, ident, rows=((), ()), response=SSE, metadata=None, body=b'{"model":"synthetic"}', started=0):
        """Write one finished capture's v1 staged rows, as the collector does."""
        zipped = lambda value: None if value is None else gzip.compress(value)
        self.db.execute("INSERT INTO captures(id,started_utc_ns,metadata_json,request_gzip,request_sha256,response_json,summary_json,state) VALUES (?,?,?,?,?,?,?,'complete')",
                        (ident, started, json.dumps({"kiro:conversation_id": "conversation", **(metadata or {})}), zipped(body),
                         None if body is None else capture.digest(body), json.dumps(response), json.dumps({"usage_objects": [{"n": 1}]})))
        self.db.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?)", [(ident, c.seq, c.utc_ns, c.mono_ns, zipped(c.entity), zipped(c.application)) for c in rows[0]])
        self.db.executemany("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", [(ident, e.seq, e.chunk_seq, e.utc_ns, e.mono_ns, e.name, zipped(e.frame), e.data) for e in rows[1]])
        self.db.commit()
        return ident

    def pending(self, *identifiers):
        self.db.executemany("INSERT INTO pending_seals VALUES (?)", [(ident,) for ident in identifiers])
        self.db.commit()

    def collect(self, writer, parts=(DELTA + event(completed()),), response=SSE, body=b'{"metadata":{"kiro:conversation_id":"sess_report"}}', **metadata):
        """One finished capture of this run's invocation through the collector."""
        ident = writer.begin({"host": "runtime.kiro.dev", "invocation": "a" * 32, **metadata}, body)
        writer.headers(ident, response)
        for part in parts:
            writer.chunk(ident, part)
        writer.finish(ident)
        return ident

    def drained(self, writer):
        """Close writer once its sealer emptied pending_seals, backlog included, which close alone would skip."""
        deadline = time.monotonic() + 5
        while self.db.execute("SELECT 1 FROM pending_seals").fetchone() and time.monotonic() < deadline:
            time.sleep(.01)
        writer.close()

    def sealed(self):
        return {ident for (ident,) in self.db.execute("SELECT capture_id FROM capture_facts")}

    def read(self, ident, db=None):
        db = db or self.db
        return store.request_body(db, ident), store.response_rows(db, ident), store.payload_bytes(db, ident)

    def facts(self, ident):
        present = store.tables(self.db)
        columns = query.fact_columns(present)
        return tuple(self.db.execute(f"SELECT {','.join(columns.values())} FROM captures c LEFT JOIN capture_facts f ON f.capture_id=c.id WHERE c.id=?", (ident,)).fetchone())

    def test_seal_round_trips_every_staged_shape(self):
        nulls = ([Chunk(0, None, None, None, None), Chunk(1, 5, 6, b"", b""), Chunk(3, 7, 8, b"ab", None)],
                 [Event(0, None, None, None, None, None, None), Event(1, 1, 5, 6, "", b"", "{}"), Event(2, 3, 7, 8, "json", None, '{"a":1}')])
        shapes = {"eventstream": (staged([aws_event("assistantResponseEvent", {"content": "hi"})], parser="eventstream"), {}, {"target": "rpc"}, b"request"),
                  "gzip": (staged(split(gzip.compress(event(completed())), 9), "gzip"), {**SSE, "content_encoding": "gzip"}, {}, b"request"),
                  "interrupted": (staged([event(completed())]), {}, {}, b"request"),
                  "nulls": (nulls, {}, {}, None),
                  "sse": (staged(split(DELTA + event(completed()), 30)), SSE, {}, b"request"),
                  "unsupported": (staged([b"\x01\x02"], "br"), {**SSE, "content_encoding": "br"}, {}, b"request")}
        for name, (rows, response, metadata, body) in shapes.items():
            with self.subTest(name):
                ident = self.stage(name, rows, response, {**metadata, "kiro:conversation_id": name}, body)
                before, facts = self.read(ident), self.facts(ident)
                live = tuple(self.db.execute(f"SELECT {','.join(query.FACTS.values())} FROM captures c WHERE c.id=?", (ident,)).fetchone())
                delta = store.seal(self.db, ident)
                self.assertEqual(self.read(ident)[:2], before[:2])
                self.assertEqual(self.read(ident)[2] - before[2], delta)
                self.assertEqual(tuple(self.db.execute(f"SELECT {','.join(query.FACTS)} FROM capture_facts WHERE capture_id=?", (ident,)).fetchone()), live)
                self.assertEqual(self.facts(ident), facts)
                self.assertEqual(tuple(self.db.execute("SELECT (SELECT count(*) FROM chunks WHERE capture_id=?)+(SELECT count(*) FROM events WHERE capture_id=?),"
                                                 "(SELECT request_gzip FROM captures WHERE id=?)", (ident,) * 3).fetchone()), (0, None))
                self.assertEqual(store.seal(self.db, ident), 0)
        self.db.execute("UPDATE capture_meta SET version=1")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "version 2"):
            store.seal(self.db, self.stage("v1"))

    def test_payload_without_hash_is_never_sealed(self):
        for ident, update in (("payload", "request_sha256=NULL"), ("hash", "request_gzip=NULL")):
            with self.subTest(ident):
                self.stage(ident)
                self.db.execute(f"UPDATE captures SET {update} WHERE id=?", (ident,))
                self.db.commit()
                for call in (store.request_body, store.seal):
                    with self.assertRaisesRegex(ValueError, "disagree"):
                        call(self.db, ident)
                self.assertIsNone(self.db.execute("SELECT 1 FROM capture_facts").fetchone())

    def test_requests_chain_to_the_previous_request_of_their_conversation(self):
        bodies = {ident: b'{"history":[' + b'"turn",' * index + b'"next"]}' for index, ident in enumerate("abc")}
        for index, (ident, body) in enumerate(bodies.items()):
            self.stage(ident, body=body, started=index)
        self.stage("other", metadata={"kiro:conversation_id": "other"}, started=3)
        for ident in ("c", "a", "b", "other"):  # c seals against a still-staged base; its base sealing later changes nothing
            store.seal(self.db, ident)
        self.assertEqual(dict(self.db.execute("SELECT capture_id,base_id FROM sealed_requests")), {"a": None, "b": "a", "c": "b", "other": None})
        for ident, body in bodies.items():
            self.assertEqual(store.request_body(self.db, ident), body)
        self.db.execute("UPDATE sealed_requests SET base_id='c' WHERE capture_id='a'")
        with self.assertRaisesRegex(ValueError, "cyclic request base"):
            store.request_body(self.db, "c")
        self.db.execute("DELETE FROM captures WHERE id='a'")
        with self.assertRaisesRegex(ValueError, "missing request base"):
            store.request_body(self.db, "c")

    def test_an_omitted_base_fails_its_sealed_dependent(self):
        self.stage("a", body=b"base request body", started=0)
        self.stage("b", body=b"base request body plus a turn", started=1)
        store.seal(self.db, "b")
        self.db.execute("UPDATE captures SET request_gzip=NULL,request_sha256=NULL WHERE id='a'")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "missing request base"):
            store.request_body(self.db, "b")
        self.assertIsNone(store.request_body(self.db, "a"))

    def test_corrupt_staged_gzip_fails_verification(self):
        for column, table in (("request_gzip", "captures"), ("entity_gzip", "chunks"), ("application_gzip", "chunks"), ("frame_gzip", "events")):
            with self.subTest(column):
                ident = self.stage(column, ([Chunk(0, 1, 2, b"x", b"x")], [Event(0, 0, 1, 2, "n", b"x", "{}")]))
                key = "id" if table == "captures" else "capture_id"
                self.db.execute(f"UPDATE {table} SET {column}=? WHERE {key}=?", (b"not gzip", ident))
                self.db.commit()
                with self.assertRaisesRegex(ValueError, "corrupt staged payload"):
                    store.request_body(self.db, ident) if table == "captures" else store.response_rows(self.db, ident)

    def test_a_deep_chain_decodes_iteratively(self):
        base = None
        for index in range(1500):
            body = b"request %d of a long conversation" % index
            self.db.execute("INSERT INTO captures(id,request_sha256) VALUES (?,?)", (str(index), capture.digest(body)))
            self.db.execute("INSERT INTO sealed_requests VALUES (?,?,?)", (str(index), None if index == 0 else str(index - 1), codec.compress_request(body, base)))
            base = body
        self.assertEqual(store.request_body(self.db, "1499"), base)

    def test_request_cache_hits_and_misses_seal_alike(self):
        bodies = [b"%d shared request prefix" % index for index in range(3)]
        for index, body in enumerate(bodies):
            self.stage(str(index), body=body, started=index)
        cache = store.RequestCache(budget=48)
        for ident in "120":  # 1 misses its base 0; 2 finds its base 1 cached
            store.seal(self.db, ident, cache)
        for index in (1, 2):
            self.assertEqual(self.db.execute("SELECT body_zstd FROM sealed_requests WHERE capture_id=?", (str(index),)).fetchone()[0],
                             codec.compress_request(bodies[index], bodies[index - 1]))
        self.assertEqual(list(cache.bodies), ["2", "0"])
        self.assertLessEqual(cache.size, 48)
        cache.put("big", b"x" * 64)
        self.assertEqual(list(cache.bodies), ["big"])

    def test_a_failed_seal_keeps_the_staged_rows(self):
        ident = self.stage("staged", staged(split(DELTA, 5)))
        before = self.read(ident)
        with patch.object(codec, "compress_response", side_effect=ValueError("seal mismatch")), self.assertRaises(ValueError):
            store.seal(self.db, ident)
        self.assertEqual(self.read(ident), before)
        self.db.execute("CREATE TEMP TRIGGER refuse BEFORE DELETE ON chunks BEGIN SELECT RAISE(ABORT, 'refused'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            store.seal(self.db, ident)
        self.assertEqual(self.read(ident), before)
        self.assertIsNone(self.db.execute("SELECT 1 FROM capture_facts UNION ALL SELECT 1 FROM sealed_responses").fetchone())
        self.db.execute("DROP TRIGGER refuse")
        store.seal(self.db, ident)
        self.assertEqual(self.read(ident)[:2], before[:2])

    def interleaved(self, interfere):
        """Run interfere between seal's read phase on self.db and its write phase."""
        original = store.snapshot

        @contextmanager
        def between(db):
            outer = not db.in_transaction
            with original(db):
                yield
            if outer and db is self.db:
                interfere()
        return patch.object(store, "snapshot", between)

    def test_the_write_phase_rechecks_the_staged_rows(self):
        other = self.connect()
        ident = self.stage("sealed", staged(split(DELTA, 5)))
        with self.interleaved(lambda: store.seal(other, "sealed")):
            self.assertEqual(store.seal(self.db, ident), 0)
        ident = self.stage("grown", staged(split(DELTA, 5)))
        before = self.read(ident)

        def grow():
            other.execute("INSERT INTO chunks(capture_id,seq) VALUES ('grown',9)")
            other.commit()
        with self.interleaved(grow), self.assertRaisesRegex(ValueError, "changed during seal"):
            store.seal(self.db, ident)
        self.assertIsNone(self.db.execute("SELECT 1 FROM capture_facts WHERE capture_id=?", (ident,)).fetchone())
        self.assertEqual(self.read(ident)[0], before[0])
        self.assertEqual(store.response_rows(self.db, ident)[0][:-1], before[1][0])

    def test_a_snapshot_reads_across_a_concurrent_seal(self):
        ident = self.stage("staged", staged(split(DELTA, 5)))
        before = self.read(ident)
        with store.snapshot(self.db):
            self.assertEqual(self.read(ident), before)
            self.assertNotEqual(store.seal(self.connect(), ident), 0)
            self.assertEqual(self.read(ident), before)
        self.assertEqual(self.read(ident)[:2], before[:2])
        self.assertNotEqual(self.read(ident)[2], before[2])

    def test_start_queues_every_unsealed_capture_of_an_older_collector(self):
        self.db.executescript("DROP TABLE pending_seals; DROP TABLE sealed_requests; DROP TABLE sealed_responses; DROP TABLE capture_facts;"
                              "UPDATE capture_meta SET version=1;")
        old = self.stage("old", staged(split(DELTA, 5)))
        before = self.read(old)
        with patch.object(store.Sealer, "put"):
            capture.Collector(self.path).close()
        self.assertEqual([version for (version,) in self.db.execute("SELECT version FROM capture_meta")], [2])
        self.assertEqual([row[0] for row in self.db.execute("SELECT capture_id FROM pending_seals")], [old])
        self.assertEqual(self.read(old), before)
        writer = capture.Collector(self.path)
        self.drained(writer)
        self.assertEqual(self.sealed(), {old})
        self.assertEqual(self.read(old)[:2], before[:2])
        self.assertEqual(writer.stored_bytes, store.payload_bytes(self.db))
        legacy = self.stage("legacy", staged(split(DELTA, 5)), started=1)  # a v2 store a pre-queue collector staged
        self.db.execute("DELETE FROM pending_seals")
        self.db.commit()
        writer = capture.Collector(self.path)
        self.drained(writer)
        self.assertEqual(self.sealed(), {old, legacy})
        self.db.execute("UPDATE capture_meta SET version=3")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "unsupported capture schema version"):
            capture.Collector(self.path)

    def test_the_collector_seals_its_backlog_after_its_lock_and_before_its_flock(self):
        crashed = self.stage("crashed", staged(split(DELTA, 5)))
        self.db.execute("UPDATE captures SET state='recording'")  # restart marks it interrupted, then seals it
        self.pending(crashed)
        before = self.read(crashed)
        original = store.Sealer.close

        def probed(sealer):
            with self.assertRaises(BlockingIOError):
                capture.lock_beside(self.path, ".capture.lock")
            original(sealer)
        # A seal before self.lock existed would fail in _count and print its failure line.
        with patch.object(store.Sealer, "close", probed), redirect_stderr(io.StringIO()) as stderr:
            writer = capture.Collector(self.path)
            self.drained(writer)
        self.assertEqual((stderr.getvalue(), self.sealed()), ("", {crashed}))
        self.assertEqual(self.read(crashed)[:2], before[:2])
        self.assertEqual(writer.stored_bytes, store.payload_bytes(self.db))
        restarted = capture.Collector(self.path)
        restarted.close()
        self.assertEqual(restarted.stored_bytes, writer.stored_bytes)

    def test_close_seals_this_runs_captures_and_leaves_the_backlog_pending(self):
        backlog = [self.stage(str(index), started=index) for index in range(200)]
        self.pending(*backlog, self.stage("new", started=200))
        original, calls, deltas, sealing = store.seal, [], [], threading.Event()

        def gated(db, ident, cache):
            calls.append(ident)
            sealing.set()
            sealer.stop.wait(2)  # close arrives during the first seal
            return original(db, ident, cache)
        with patch.object(store, "seal", gated):
            sealer = store.Sealer(self.path, deltas.append)
            for ident in backlog:
                sealer.put(ident, backlog=True)
            sealer.put("new")
            self.assertTrue(sealing.wait(2))
            sealer.close()
        self.assertEqual((calls, self.sealed(), len(deltas)), (["0", "new"], {"0", "new"}, 2))
        self.assertEqual(self.db.execute("SELECT count(*) FROM pending_seals").fetchone()[0], 199)

    def test_a_store_locked_at_open_is_retried_and_the_capture_sealed(self):
        self.pending(self.stage("late"))
        sealed, attempts, original = queue.Queue(), [], store.open_database

        def flaky(path):
            attempts.append(path)
            if len(attempts) == 1:
                raise sqlite3.OperationalError("database is locked")
            return original(path)
        with patch.object(store, "open_database", flaky), patch.object(store.Sealer, "RETRIES", (.01, .01)), \
                redirect_stderr(io.StringIO()) as stderr:
            sealer = store.Sealer(self.path, sealed.put)
            sealer.put("late")
            sealed.get(timeout=5)
            sealer.close()
        self.assertEqual((len(attempts), stderr.getvalue(), self.sealed()), (2, "", {"late"}))

    def test_a_busy_store_is_retried_and_close_interrupts_the_backoff(self):
        self.pending(self.stage("retried"), self.stage("abandoned"))
        blocker, original, failures, sealed = self.connect(), store.seal, queue.Queue(), queue.Queue()

        def short(path):
            db = capture.open_database(path)
            db.execute("PRAGMA busy_timeout=10")
            return db

        def observed(db, ident, cache):
            try:
                return original(db, ident, cache)
            except sqlite3.OperationalError:
                failures.put(ident)
                raise
        blocker.execute("BEGIN IMMEDIATE")
        with patch.object(store, "open_database", short), patch.object(store, "seal", observed), \
                patch.object(store.Sealer, "RETRIES", (.2, 60)), redirect_stderr(io.StringIO()) as stderr:
            sealer = store.Sealer(self.path, sealed.put)
            sealer.put("retried")
            self.assertEqual(failures.get(timeout=5), "retried")
            blocker.commit()
            sealed.get(timeout=5)  # the retry committed
            blocker.execute("BEGIN IMMEDIATE")
            sealer.put("abandoned")
            self.assertEqual([failures.get(timeout=5) for _ in range(2)], ["abandoned"] * 2)  # now waiting 60 s
            started = time.monotonic()
            sealer.close()
            self.assertLess(time.monotonic() - started, 2)
        blocker.rollback()
        self.assertEqual(self.sealed(), {"retried"})
        self.assertEqual([ident for (ident,) in self.db.execute("SELECT capture_id FROM pending_seals")], ["abandoned"])
        self.assertEqual(stderr.getvalue(), "Kiro capture: sealing abandoned failed (OperationalError); staged payloads kept\n")

    def test_expire_keeps_every_fact_and_report_and_rebases_a_kept_dependent(self):
        session, old_body = "sess_00000000-0000-0000-0000-000000000000", b'{"history":[' + b"x" * 96
        kept_body = old_body + b"],\"next\":true}"
        identity = {"kiro:conversation_id": session}
        self.stage("unsealed", staged(split(DELTA, 5)), metadata=identity, started=-1)
        self.stage("old", staged(split(DELTA, 5)), metadata=identity, body=old_body, started=0)
        self.stage("kept", staged(split(DELTA, 6)), metadata=identity, body=kept_body, started=1)
        store.seal(self.db, "old")
        store.seal(self.db, "kept")
        captures = list(self.db.execute("SELECT * FROM captures ORDER BY id"))
        facts = list(self.db.execute("SELECT * FROM capture_facts ORDER BY capture_id"))
        rendering = (query.render(query.query(self.db, session)), report.store_report(self.db))
        total = store.payload_bytes(self.db)
        delta, expired = store.expire(self.db, 1)
        self.assertEqual((expired, self.sealed()), (1, {"kept", "old"}))
        self.assertEqual([tuple(row) for row in self.db.execute("SELECT * FROM captures ORDER BY id")], [tuple(row) for row in captures])
        self.assertEqual(list(self.db.execute("SELECT * FROM capture_facts ORDER BY capture_id")), facts)
        self.assertEqual((query.render(query.query(self.db, session)), report.store_report(self.db)), rendering)
        self.assertEqual(dict(self.db.execute("SELECT capture_id,base_id FROM sealed_requests")), {"kept": None})
        self.assertEqual(store.request_body(self.db, "kept"), kept_body)
        self.assertEqual(total + delta, store.payload_bytes(self.db))
        self.stage("later", staged(split(DELTA, 7)), metadata=identity, body=kept_body + b"x", started=2)
        store.seal(self.db, "later")
        self.assertEqual(self.db.execute("SELECT base_id FROM sealed_requests WHERE capture_id='later'").fetchone()[0], "kept")

    def test_the_sealer_expires_only_with_retention_and_accounts_its_delta(self):
        old = self.stage("old", staged(split(DELTA, 5)))
        store.seal(self.db, old)
        before = store.payload_bytes(self.db)
        with patch.object(store, "expire") as expire:
            store.Sealer(self.path, lambda delta: None).close()
            expire.assert_not_called()
        writer = capture.Collector(self.path, retention_days=1)
        deadline = time.monotonic() + 5
        while self.db.execute("SELECT 1 FROM sealed_responses").fetchone() and time.monotonic() < deadline:
            time.sleep(.01)
        writer.close()
        self.assertEqual(writer.stored_bytes, store.payload_bytes(self.db))
        self.assertLess(writer.stored_bytes, before)
        self.assertEqual(list(self.db.execute("SELECT capture_id FROM sealed_responses")), [])
        self.assertEqual(self.sealed(), {old})

    def test_startup_backlog_is_sealed_before_retention(self):
        order, expired = [], threading.Event()
        def seal(sealer, cache, ident):
            order.append(ident)
        def expire(sealer, cache):
            order.append("expire")
            expired.set()
            return 0
        with patch.object(store.Sealer, "_seal", seal), patch.object(store.Sealer, "_expire", expire):
            sealer = store.Sealer(self.path, lambda delta: None, 1, ["first", "second"])
            self.assertTrue(expired.wait(2))
            sealer.close()
        self.assertEqual(order, ["first", "second", "expire"])

    def test_a_full_retention_batch_runs_again_while_idle(self):
        calls = threading.Event()
        def full_batch(*args, **keywords):
            if expire.call_count >= 2:
                calls.set()
            return -1, store.RETENTION_BATCH

        with patch.object(store, "expire", side_effect=full_batch) as expire:
            sealer = store.Sealer(self.path, lambda delta: None, 1)
            self.assertTrue(calls.wait(2))
            sealer.close()
        self.assertGreaterEqual(expire.call_count, 2)

    def test_a_failed_retention_batch_prints_once_and_waits_for_the_daily_run(self):
        calls = threading.Event()

        def failed(*arguments, **keywords):
            calls.set()
            raise ValueError("synthetic")

        with patch.object(store, "expire", side_effect=failed) as expire, redirect_stderr(io.StringIO()) as stderr:
            sealer = store.Sealer(self.path, lambda delta: None, 1)
            self.assertTrue(calls.wait(2))
            time.sleep(.2)
            sealer.close()
        self.assertEqual(expire.call_count, 1)
        self.assertEqual(stderr.getvalue(), "Kiro capture: retention batch failed (ValueError); payloads kept\n")

    def reports(self, first):
        """Every report and calibration read over the store; capture evidence and fits over the complete first capture."""
        with closing(sqlite3.connect(self.path)) as db:
            session, tree = query.query(db, "sess_report"), query.query(db, "sess_report", "tree")
            started = db.execute("SELECT started_utc_ns FROM captures WHERE id=?", (first,)).fetchone()[0]
            manifest = {"calls": [{"status": "complete", "capture_count": 1, "captures": [{"id": first}], "label": "call", "model": "claude-opus-5.5"}]}
            return (session, tree, query.render(session), query.render_summary(tree), query.run_report(db, "a" * 32, "sess_report"),
                    report.store_report(db), calibration.capture_evidence(db, "sess_report", started, started), calibration.fit_calls(db, manifest))

    def test_reports_read_alike_before_and_after_sealing_and_expiry(self):
        delta = lambda kind, text: event({"type": kind, "delta": text})
        text_only = {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": "only"}]}],
                                                                "usage": {**completed()["response"]["usage"], "kiro:context_usage_percentage": 1.8}}}
        with patch.object(store.Sealer, "put"), redirect_stderr(io.StringIO()):  # both runs leave every capture staged and pending
            writer = capture.Collector(self.path)
            first = self.collect(writer, [delta("response.output_text.delta", "a"), delta("response.function_call_arguments.delta", "{}"),
                                          delta("response.reasoning_text.delta", "why"), event(completed())])
            self.collect(writer, [event(text_only)],  # reaches the credit-discount payload facts
                         body=b'{"model":"claude-opus-5.5","reasoning":{"effort":"low"},"metadata":{"kiro:conversation_id":"sess_report"}}')
            self.collect(writer, [aws_event("assistantResponseEvent", {"content": "hi"}), aws_event("meteringEvent", {"usage": .5, "unit": "credit"})],
                         {"content_type": EVENTSTREAM}, b'{"conversationState":{"conversationId":"sess_report"}}', target=GENERATE)
            interrupted = self.collect(writer, [json.dumps(completed()["response"]).encode()], {"content_type": "application/json"})
            writer.close()
            self.db.execute("UPDATE captures SET state='recording' WHERE id=?", (interrupted,))  # a crash before its finalize committed
            self.db.commit()
            writer = capture.Collector(self.path, max_bytes=4096)  # marks it interrupted
            self.collect(writer, [delta("response.output_text.delta", "x" * 8192), event(completed())],
                         body=b'{"metadata":{"kiro:conversation_id":"sess_report"},"padding":"' + b"x" * 8192 + b'"}')  # both copies refused
            writer.close()
        before = self.reports(first)
        self.drained(capture.Collector(self.path))
        self.assertEqual(len(self.sealed()), 5)
        self.assertEqual(self.reports(first), before)
        store.expire(self.db, time.time_ns() + 1)
        self.assertEqual(self.reports(first), before)


if __name__ == "__main__":
    unittest.main()

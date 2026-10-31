"""Synthetic staged and sealed capture stores; readers, seal, base chains and payload accounting."""

from contextlib import contextmanager
import gzip
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import capture
import codec
from codec import Chunk, Event
import query
import store
from test_capture import aws_event, completed, event
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


if __name__ == "__main__":
    unittest.main()

"""Synthetic sealed-payload codec contracts; pure bytes, no SQLite."""

import base64
import contextlib
import gzip
import json
from pathlib import Path
import random
import struct
import unittest
import zlib
from unittest.mock import patch

from compression import zstd

from capture import DECODE_LIMIT, SSE, Analysis, EventStream, content_decoder, decode_chunk, event_text, packed
import codec
from codec import MIN_BASE, Chunk, Event, compress_request, compress_response, decompress_request, decompress_response
from test_capture import aws_event, aws_message, completed, event

GOLDEN = json.loads((Path(__file__).parent / "fixtures/codec-golden.json").read_text())
LARGE = 4 * 1024 * 1024 + 1  # past the SSE and event-stream frame limit


def staged(parts, encoding="identity", parser="sse", drop=()):
    """The chunk and event rows the collector stages for these entity chunks.

    drop: seqs the queue refused; parsing still saw their bytes, and their events are lost with them."""
    chunks, events, pending = [], [], []
    analysis = Analysis(lambda seq, name, frame, obj: pending.append((seq, name, frame, event_text(obj))))
    framing = {"eventstream": EventStream(analysis.message), "sse": SSE(analysis.event)}.get(parser)
    decoder = content_decoder(encoding)
    failed = decoder is None and encoding != "identity"
    for seq, part in enumerate(parts):
        application = None
        if not failed:
            application, ok = decode_chunk(decoder, part)
            failed = not ok
            if ok and framing:
                framing.feed(application)
        if seq not in drop:
            chunks.append(Chunk(seq, 10 + seq, 20 + seq, part, application))
            events += [Event(n, seq, 10 + seq, 20 + seq, name, frame, text) for n, name, frame, text in pending]
        pending.clear()
    if framing:
        framing.feed(b"", final=True)  # the EOF tail, written at finalize with the last chunk's stamp
        events += [Event(n, seq, 10 + seq, 20 + seq, name, frame, text) for n, name, frame, text in pending]
    return chunks, events


def split(body, *offsets):
    return [body[a:b] for a, b in zip((0, *offsets), (*offsets, len(body)))]


def rows(response):
    """A fixture response's expected rows; bytes fields are base64."""
    raw = lambda value: None if value is None else base64.b64decode(value)
    return ([Chunk(seq, utc_ns, mono_ns, raw(entity), raw(app)) for seq, utc_ns, mono_ns, entity, app in response["chunks"]],
            [Event(seq, chunk_seq, utc_ns, mono_ns, name, raw(frame), data) for seq, chunk_seq, utc_ns, mono_ns, name, frame, data in response["events"]])


class RequestTests(unittest.TestCase):
    def test_round_trip_with_and_without_base(self):
        for base in (None, b"8 bytes!"):
            for body in (b"", b'{"model":"synthetic"}'):
                with self.subTest(base=base, body=body):
                    self.assertEqual(decompress_request(compress_request(body, base), base), body)
        with self.assertRaises(ValueError):
            compress_request(b"body", b"x" * (MIN_BASE - 1))

    def test_prefix_reaches_a_whole_multi_mib_base(self):
        # A direct raw dictionary loses matches past ~4 MiB back; random bytes leave only those matches to compress.
        base = random.Random(0).randbytes(6 * 1024 * 1024)
        blob = compress_request(base[:1024 * 1024], base)
        self.assertLess(len(blob), 10 * 1024)
        self.assertEqual(decompress_request(blob, base), base[:1024 * 1024])

    def test_base_longer_than_the_window_still_round_trips(self):
        base = random.Random(1).randbytes(3 * 1024 * 1024)
        with patch.dict(codec.REQUEST_OPTIONS, {zstd.CompressionParameter.window_log: 20}):
            blob = compress_request(base[:256 * 1024] + b"tail", base)
        self.assertEqual(decompress_request(blob, base), base[:256 * 1024] + b"tail")

    def test_wrong_base_never_returns_the_body(self):
        body = b'{"history":["first","second"]}' * 8
        blob = compress_request(body, body[:64])
        with contextlib.suppress(ValueError):
            self.assertNotEqual(decompress_request(blob, b"x" * 64), body)


class ResponseTests(unittest.TestCase):
    def round_trip(self, chunks, events, encoding="identity", parser="sse"):
        """Assert an exact round trip; returns the recipe and the exceptions heap."""
        blobs = compress_response(encoding, parser, chunks, events)
        self.assertEqual(decompress_response(*blobs), (chunks, events))
        return json.loads(zstd.decompress(blobs[1])), zstd.decompress(blobs[2])

    def assert_derived(self, chunks, events, encoding="identity", parser="sse"):
        recipe, heap = self.round_trip(chunks, events, encoding, parser)
        self.assertEqual(heap, b"")
        self.assertTrue(all(chunk[-1] in (0, None) for chunk in recipe["chunks"]))
        self.assertTrue(all(event[-1] == 0 for event in recipe["events"]))

    def test_numeric_recipe_fields_must_be_exact_ints(self):
        chunks, events = staged([event(completed())])
        transport, recipe, heap = compress_response("identity", "sse", chunks, events)
        parsed = json.loads(zstd.decompress(recipe))
        for path in (("chunks", 0, 0), ("chunks", 0, 3), ("events", 0, 0), ("events", 0, 2)):
            for bad in ("0", 0.0, True, [0]):
                with self.subTest(path=path, bad=bad):
                    mutated = json.loads(json.dumps(parsed))
                    mutated[path[0]][path[1]][path[2]] = bad
                    blob = zstd.compress(json.dumps(mutated).encode())
                    with self.assertRaises(ValueError):
                        decompress_response(transport, blob, heap)

    def test_sse_derives_every_row(self):
        body = (event({"type": "response.output_text.delta", "delta": "é🙂"}) + b"data: [DONE]\n\n"
                + b'event: note\r\ndata: {"a":\r\ndata: 1}\r\n\r\n' + b'data: {"tail":1}')
        chunks, events = staged([body[i:i + 1] for i in range(len(body))])
        self.assertEqual([e.data for e in events], ['{"delta":"é🙂","type":"response.output_text.delta"}', None, '{"a":1}', None])
        self.assert_derived(chunks, events)

    def test_sse_frame_past_the_limit_disables_parsing(self):
        body = event({"type": "response.output_text.delta", "delta": "x"}) + b"data: " + b"x" * LARGE + b"\n\n" + event(completed())
        chunks, events = staged(split(body, 1024 * 1024, 2 * 1024 * 1024, 3 * 1024 * 1024))
        self.assertEqual(len(events), 1)
        self.assert_derived(chunks, events)

    def test_event_stream_derives_valid_and_failed_frames(self):
        valid = aws_event("assistantResponseEvent", {"content": "hi"}) + aws_event("meteringEvent", {"unit": "credit", "usage": 0.5})
        prelude = struct.pack(">II", 8, 0)
        cases = {"crc": valid + aws_event("assistantResponseEvent", {"content": "x"}, corrupt=1),
                 "limit": valid + aws_message({":message-type": "event"}, b"x" * LARGE),
                 "prelude": valid + prelude + struct.pack(">I", zlib.crc32(prelude)) + b"ignored",
                 "tail": valid + aws_event("assistantResponseEvent", {"content": "x"})[:20],
                 "valid": valid}
        for name, body in cases.items():
            with self.subTest(name):
                chunks, events = staged(split(body, 7, len(valid) + 3), parser="eventstream")
                self.assertEqual(len(events), 2 if name in ("valid", "limit") else 3)
                self.assert_derived(chunks, events, parser="eventstream")

    def test_non_identity_applications_derive(self):
        body = event(completed())
        encoded = gzip.compress(body)
        cases = {"corrupt": ("gzip", [encoded[:20], b"\xff" * 16, encoded[20:]]),
                 "deflate": ("deflate", split(zlib.compress(body), 5, 30)),
                 "gzip": ("gzip", split(encoded, 9, 20)),
                 "multi_member": ("gzip", split(encoded + gzip.compress(b"more"), 9, len(encoded) + 4)),
                 "over_limit": ("gzip", [gzip.compress(b"\0" * (DECODE_LIMIT + 1)), gzip.compress(b"later")]),
                 "truncated": ("gzip", split(encoded[:-8], 9))}
        for name, (encoding, parts) in cases.items():
            with self.subTest(name):
                chunks, events = staged(parts, encoding)
                if name in ("corrupt", "over_limit"):
                    self.assertIsNone(chunks[-1].application)
                if name == "over_limit":
                    self.assertEqual(len(chunks[0].application), DECODE_LIMIT + 1)
                self.assert_derived(chunks, events, encoding)

    def test_dropped_chunks_store_exceptions(self):
        body = event({"type": "response.output_text.delta", "delta": "a"}) + event({"type": "response.output_text.delta", "delta": "b"}) + event(completed())
        first = len(event({"type": "response.output_text.delta", "delta": "a"}))
        for encoding, parts in (("gzip", split(gzip.compress(body), 40, 80)), ("identity", split(body, first, first + 5))):
            with self.subTest(encoding):
                chunks, events = staged(parts, encoding, drop={1})
                self.assertEqual([chunk.seq for chunk in chunks], [0, 2])
                recipe, heap = self.round_trip(chunks, events, encoding)
                self.assertNotEqual(heap, b"")
                if encoding == "gzip":
                    self.assertIsInstance(recipe["chunks"][1][-1], list)
                else:
                    self.assertEqual(recipe["events"][1][4][0], "x")  # the second event's frame began in chunk 1

    def test_null_and_empty_stay_distinct(self):
        chunks = [Chunk(0, None, None, None, None), Chunk(1, 5, 6, b"", b""), Chunk(3, 7, 8, b"ab", None), Chunk(4, 9, 9, None, b"x")]
        events = [Event(0, None, None, None, None, None, None), Event(1, 1, 5, 6, "", b"", ""),
                  Event(2, 3, 7, 8, "message", None, '{"a":1}'), Event(3, 4, 9, 9, "json", None, packed({"k": "é"}))]
        self.round_trip(chunks, events)

    def test_unsupported_encoding_keeps_null_applications(self):
        chunks, events = staged([b"\x01\x02", b"\x03"], "br")
        self.assertEqual([chunk.application for chunk in chunks], [None, None])
        self.assert_derived(chunks, events, "br")

    def test_interrupted_capture_stores_every_event_as_an_exception(self):
        # Interrupted before finalize, response_json stays "{}": identity, and no parser for a non-RPC capture.
        chunks, events = staged(split(event(completed()) + event(completed()), 30))
        recipe, _ = self.round_trip(chunks, events, parser=None)
        self.assertTrue(all(isinstance(event[-1], list) for event in recipe["events"]))

    def test_derivation_mismatch_is_an_exception(self):
        chunks, events = staged([event(completed())])
        events[0] = events[0]._replace(data='{"other":1}')
        recipe, _ = self.round_trip(chunks, events)
        self.assertEqual(recipe["events"][0][-1][0], "message")

    def test_tampered_blobs_refuse(self):
        chunks, events = staged([event(completed())])
        events[0] = events[0]._replace(data='{"other":1}')
        transport, recipe, exceptions = compress_response("identity", "sse", chunks, events)
        decoded = json.loads(zstd.decompress(recipe))
        heap = bytearray(zstd.decompress(exceptions))
        heap[0] ^= 1
        for name, change in (("digest", lambda r: r["chunks"][0].__setitem__(1, 11)), ("version", lambda r: r.__setitem__("v", 2))):
            with self.subTest(name):
                changed = json.loads(json.dumps(decoded))
                change(changed)
                with self.assertRaisesRegex(ValueError, name):
                    decompress_response(transport, zstd.compress(packed(changed).encode()), exceptions)
        with self.assertRaisesRegex(ValueError, "digest"):
            decompress_response(transport, recipe, zstd.compress(bytes(heap)))
        with self.assertRaises(ValueError):
            decompress_response(transport, recipe[:-1], exceptions)

    def test_golden_blobs_decode(self):
        # Sealed captures outlive the parsers: a change that alters this derivation needs a new RECIPE_VERSION.
        blob = lambda value: base64.b64decode(value)
        for request in GOLDEN["requests"]:
            base = None if request["base"] is None else blob(request["base"])
            self.assertEqual(decompress_request(blob(request["blob"]), base), blob(request["body"]))
        for response in GOLDEN["responses"]:
            self.assertEqual(decompress_response(*map(blob, response["blobs"])), rows(response))


if __name__ == "__main__":
    unittest.main()

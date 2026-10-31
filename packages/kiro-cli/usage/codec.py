"""Lossless zstd blobs for sealed capture payloads; pure bytes in and out, no SQLite.

A request is compressed against the previous request of its conversation as a raw-content prefix. A response keeps
its entity bytes as one transport stream and rebuilds application bytes, frames and event data from them by replaying
the collector's decoder and parsers; the recipe stores only what that replay does not reproduce."""

import hashlib
import json
import struct
from typing import NamedTuple

from compression import zstd

from capture import SSE, Analysis, EventStream, content_decoder, decode_chunk, event_text, packed


class Chunk(NamedTuple):
    seq: int
    utc_ns: int | None
    mono_ns: int | None
    entity: bytes | None
    application: bytes | None


class Event(NamedTuple):
    seq: int
    chunk_seq: int | None
    utc_ns: int | None
    mono_ns: int | None
    name: str | None
    frame: bytes | None
    data: str | None


LEVEL = 9
MIN_BASE = 8  # ZstdDict refuses shorter prefix content; the store gives such a request no base.
# The prefix with long-distance matching reaches a whole multi-MiB base, which a direct raw dictionary loses past ~4 MiB.
# A base plus body beyond the 2^26 window only loses matches; the default 2^27 decoder limit still covers it.
REQUEST_OPTIONS = {zstd.CompressionParameter.compression_level: LEVEL,
                   zstd.CompressionParameter.enable_long_distance_matching: 1,
                   zstd.CompressionParameter.window_log: 26}
# Bump when a parser or packed change alters derived event data, keeping the old derivation to read v1 recipes.
RECIPE_VERSION = 1
PARSERS = {"eventstream": (EventStream, "message"), "sse": (SSE, "event")}


def compress_request(body, base):
    """base: the raw body of the request this one extends, or None for an independent frame."""
    if base is None:
        return zstd.compress(body, level=LEVEL)
    return zstd.compress(body, options=REQUEST_OPTIONS, zstd_dict=zstd.ZstdDict(base, is_raw=True).as_prefix)


def decompress_request(blob, base):
    """The caller checks the result against request_sha256: a wrong base can decode to other bytes."""
    try:
        return zstd.decompress(blob, zstd_dict=None if base is None else zstd.ZstdDict(base, is_raw=True).as_prefix)
    except zstd.ZstdError as error:
        raise ValueError("corrupt sealed request") from error


def _applications(encoding, entities):
    """The application bytes the collector decodes from each stored entity in order; None after its first failure.

    Chunks the queue dropped are absent here, so a gzip or deflate stream past a gap derives other bytes; the
    recipe stores those chunks as exceptions."""
    decoder = content_decoder(encoding)
    failed = decoder is None and encoding != "identity"  # The collector decodes nothing in an unsupported encoding.
    for entity in entities:
        if failed or entity is None:
            yield None
            continue
        application, ok = decode_chunk(decoder, entity)
        failed = not ok
        yield application


def _event_data(parser, frame):
    """(name, data_json) one frame parses to alone, or None unless it emits exactly one event."""
    if parser is None or frame is None:
        return None
    saved = []
    analysis = Analysis(lambda seq, name, frame, obj: saved.append((name, event_text(obj))))
    framing, method = PARSERS[parser]
    framing(getattr(analysis, method)).feed(frame, final=True)
    return saved[0] if len(saved) == 1 else None


def _digest(chunks, events):
    """SHA-256 over every field, each a signed 8-byte length (-1 for NULL) and its bytes; integers as decimal."""
    hasher = hashlib.sha256()
    for row in ((len(chunks), len(events)), *chunks, *events):
        for field in row:
            value = None if field is None else str(field).encode() if isinstance(field, int) else field.encode() if isinstance(field, str) else field
            hasher.update(struct.pack(">q", -1 if value is None else len(value)) + (value or b""))
    return hasher.hexdigest()


def _span(source, span):
    offset, length = span
    return source[offset:offset + length]


def _whole(value, nullable=False):
    """An exact int (never a bool, str or float), or None where the field is nullable; the digest cannot tell 0 from "0"."""
    if type(value) is int or (nullable and value is None):
        return value
    raise ValueError("corrupt sealed response")


def _stored_span(span):
    if type(span) is not list or len(span) != 2:
        raise ValueError("corrupt sealed response")
    return [_whole(part) for part in span]


def _checked(recipe):
    """The recipe's rows with every numeric field proven an exact int, so decoding cannot return a wrong type."""
    chunks, events = [], []
    for seq, utc_ns, mono_ns, size, app in recipe["chunks"]:
        app = _stored_span(app) if type(app) is list else _whole(app, True)
        if app not in (None, 0) and type(app) is not list:
            raise ValueError("corrupt sealed response")
        chunks.append([_whole(seq), _whole(utc_ns, True), _whole(mono_ns, True), _whole(size, True), app])
    for seq, chunk_seq, utc_ns, mono_ns, frame, data in recipe["events"]:
        if frame is not None:
            if type(frame) is not list:
                raise ValueError("corrupt sealed response")
            frame = ["x", *_stored_span(frame[1:])] if frame[:1] == ["x"] else _stored_span(frame)
        if type(data) is list and len(data) == 2 and (data[0] is None or type(data[0]) is str):
            data = [data[0], None if data[1] is None else _stored_span(data[1])]
        elif type(data) is not int:
            raise ValueError("corrupt sealed response")
        events.append([_whole(seq), _whole(chunk_seq, True), _whole(utc_ns, True), _whole(mono_ns, True), frame, data])
    return chunks, events


def compress_response(encoding, parser, chunks, events):
    """(transport_zstd, recipe_zstd, exceptions_zstd) for one capture's staged rows in seq order.

    encoding is content_encoding(response) and parser framing_kind(response, rpc), as the collector chose them.
    Decodes its own output and raises ValueError unless every row comes back exactly."""
    chunks, events = [Chunk(*row) for row in chunks], [Event(*row) for row in events]
    heap = bytearray()

    def stored(value):
        heap.extend(value)
        return [len(heap) - len(value), len(value)]

    recipe_chunks = [[chunk.seq, chunk.utc_ns, chunk.mono_ns, None if chunk.entity is None else len(chunk.entity),
                      None if chunk.application is None else 0 if chunk.application == derived else stored(chunk.application)]
                     for chunk, derived in zip(chunks, _applications(encoding, [chunk.entity for chunk in chunks]))]
    app = b"".join(chunk.application for chunk in chunks if chunk.application is not None)
    recipe_events, cursor = [], 0
    for event in events:
        frame, offset = None, -1 if event.frame is None else app.find(event.frame, cursor)
        if offset >= 0:
            frame, cursor = [offset, len(event.frame)], offset + len(event.frame)
        elif event.frame is not None:  # spans a dropped chunk, or was never part of the stored application bytes
            frame = ["x", *stored(event.frame)]
        data = 0 if _event_data(parser, event.frame) == (event.name, event.data) else [event.name, None if event.data is None else stored(event.data.encode())]
        recipe_events.append([event.seq, event.chunk_seq, event.utc_ns, event.mono_ns, frame, data])
    recipe = {"chunks": recipe_chunks, "digest": _digest(chunks, events), "encoding": encoding, "events": recipe_events,
              "parser": parser, "v": RECIPE_VERSION}
    transport = b"".join(chunk.entity for chunk in chunks if chunk.entity is not None)
    blobs = tuple(zstd.compress(value, level=LEVEL) for value in (transport, packed(recipe).encode(), bytes(heap)))
    try:
        exact = decompress_response(*blobs) == (chunks, events)
    except ValueError:
        exact = False
    if not exact:
        raise ValueError("seal mismatch")
    return blobs


def decompress_response(transport, recipe, exceptions):
    """(chunks, events) exactly as staged; ValueError on an unknown recipe version, a corrupt blob or a digest mismatch."""
    try:
        recipe = json.loads(zstd.decompress(recipe))
        if recipe["v"] != RECIPE_VERSION:
            raise ValueError("unknown sealed response recipe version")
        raw, heap = zstd.decompress(transport), zstd.decompress(exceptions)
        recipe_chunks, recipe_events = _checked(recipe)
        entities, cursor = [], 0
        for *_, size, _ in recipe_chunks:
            entities.append(None if size is None else raw[cursor:cursor + size])
            cursor += size or 0
        chunks = [Chunk(seq, utc_ns, mono_ns, entity, None if app is None else derived if app == 0 else _span(heap, app))
                  for (seq, utc_ns, mono_ns, _, app), entity, derived in zip(recipe_chunks, entities, _applications(recipe["encoding"], entities))]
        app = b"".join(chunk.application for chunk in chunks if chunk.application is not None)
        events = []
        for seq, chunk_seq, utc_ns, mono_ns, frame, data in recipe_events:
            frame = None if frame is None else _span(heap, frame[1:]) if frame[0] == "x" else _span(app, frame)
            name, text = _event_data(recipe["parser"], frame) if data == 0 else (data[0], None if data[1] is None else _span(heap, data[1]).decode())
            events.append(Event(seq, chunk_seq, utc_ns, mono_ns, name, frame, text))
        matches = _digest(chunks, events) == recipe["digest"]
    except (AttributeError, IndexError, KeyError, TypeError, zstd.ZstdError) as error:
        raise ValueError("corrupt sealed response") from error
    if not matches:
        raise ValueError("sealed response digest mismatch")
    return chunks, events

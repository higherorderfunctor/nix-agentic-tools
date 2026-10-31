"""SQLite capture storage; load codec lazily so staged readers do not require compression.zstd."""

from collections import OrderedDict
import gzip
import json
import zlib

from capture import content_encoding, digest, framing_kind, packed, snapshot


# (table, capture key, payload bytes per row) for payload_bytes; the sealed tables are absent from an older store.
PAYLOADS = (("captures", "id", "length(request_gzip)"),
            ("chunks", "capture_id", "COALESCE(length(entity_gzip),0)+COALESCE(length(application_gzip),0)"),
            ("events", "capture_id", "COALESCE(length(frame_gzip),0)+COALESCE(length(CAST(data_json AS BLOB)),0)"),
            ("sealed_requests", "capture_id", "length(body_zstd)"),
            ("sealed_responses", "capture_id", "length(transport_zstd)+length(recipe_zstd)+length(exceptions_zstd)"))


def staged_bytes(blob):
    """A staged gzip column decompressed; None stays None, and corrupt gzip is a ValueError."""
    try:
        return None if blob is None else gzip.decompress(blob)
    except (gzip.BadGzipFile, EOFError, zlib.error):
        raise ValueError("corrupt staged payload") from None


def tables(db):
    return {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def request_body(db, capture_id):
    """The exact request bytes, or None when the request was omitted.

    ValueError when the payload and its hash disagree, a base is missing, or the bytes fail request_sha256. Walks the
    base chain iteratively: a conversation's chain is as long as the conversation."""
    with snapshot(db):
        sealed = "sealed_requests" in tables(db)
        columns = "c.request_gzip,c.request_sha256," + ("s.base_id,s.body_zstd FROM captures c LEFT JOIN sealed_requests s ON s.capture_id=c.id"
                                                        if sealed else "NULL,NULL FROM captures c")
        chain, ident, seen = [], capture_id, set()  # (sha, gzip, zstd) from this capture back to an independent body
        while True:
            if ident in seen:
                raise ValueError("cyclic request base")
            seen.add(ident)
            row = db.execute(f"SELECT {columns} WHERE c.id=?", (ident,)).fetchone()
            if row is None:
                raise ValueError("missing request base" if chain else "unknown capture")
            staged, sha, base, blob = row
            if (staged is None and blob is None) != (sha is None):
                raise ValueError("request payload and hash disagree")
            if sha is None:
                if chain:
                    raise ValueError("missing request base")
                return None
            chain.append((sha, staged, blob))
            if staged is not None or base is None:
                break
            ident = base
        body = None
        for sha, staged, blob in reversed(chain):
            if staged is None:
                import codec
                body = codec.decompress_request(blob, body)
            else:
                body = staged_bytes(staged)
            if digest(body) != sha:
                raise ValueError("request hash mismatch")
        return body


def response_rows(db, capture_id):
    """(chunks, events) exactly as staged, in seq order, with gzip columns decompressed.

    Staged rows are plain tuples in codec.Chunk and codec.Event field order; sealed rows are those tuples."""
    with snapshot(db):
        if "sealed_responses" in tables(db):
            sealed = db.execute("SELECT transport_zstd,recipe_zstd,exceptions_zstd FROM sealed_responses WHERE capture_id=?", (capture_id,)).fetchone()
            if sealed is not None:
                import codec
                return codec.decompress_response(*sealed)
        chunks = [(seq, utc_ns, mono_ns, staged_bytes(entity), staged_bytes(application)) for seq, utc_ns, mono_ns, entity, application in db.execute(
            "SELECT seq,utc_ns,mono_ns,entity_gzip,application_gzip FROM chunks WHERE capture_id=? ORDER BY seq", (capture_id,))]
        events = [(seq, chunk_seq, utc_ns, mono_ns, name, staged_bytes(frame), data) for seq, chunk_seq, utc_ns, mono_ns, name, frame, data in db.execute(
            "SELECT seq,chunk_seq,utc_ns,mono_ns,event_name,frame_gzip,data_json FROM events WHERE capture_id=? ORDER BY seq", (capture_id,))]
        return chunks, events


def payload_bytes(db, capture_id=None):
    """Compressed payload bytes the store keeps, staged or sealed, plus usage summaries; one capture's when given.

    The collector's startup count and the exit summary's warning; a seal changes it by the delta seal returns."""
    where, parameters = ("", ()) if capture_id is None else (" WHERE {}=?", (capture_id,))
    with snapshot(db):
        present = tables(db)
        total = sum(db.execute(f"SELECT SUM({size}) FROM {table}" + where.format(key), parameters).fetchone()[0] or 0
                    for table, key, size in PAYLOADS if table in present)
        return total + sum(len(packed(usage).encode())
                           for (summary,) in db.execute("SELECT summary_json FROM captures" + where.format("id"), parameters)
                           if summary is not None and (usage := json.loads(summary).get("usage_objects")))


class RequestCache:
    """Byte-budgeted LRU of raw requests by capture ID; one oversized body stays alone."""

    def __init__(self, budget=64 * 2**20):
        self.budget, self.size, self.bodies = budget, 0, OrderedDict()

    def get(self, capture_id):
        body = self.bodies.get(capture_id)
        if body is not None:
            self.bodies.move_to_end(capture_id)
        return body

    def put(self, capture_id, body):
        self.bodies[capture_id] = body
        self.size += len(body)
        while self.size > self.budget and len(self.bodies) > 1:
            self.size -= len(self.bodies.popitem(last=False)[1])


def _staged(db, capture_id):
    """None when the capture is unknown, recording or sealed; else what the write phase rechecks of its staged rows."""
    row = db.execute("""SELECT c.state='recording' OR EXISTS(SELECT 1 FROM capture_facts f WHERE f.capture_id=c.id),c.request_gzip IS NULL,
        (SELECT count(*) FROM chunks k WHERE k.capture_id=c.id),(SELECT count(*) FROM events e WHERE e.capture_id=c.id)
        FROM captures c WHERE c.id=?""", (capture_id,)).fetchone()
    return None if row is None or row[0] else (*row[1:], payload_bytes(db, capture_id))


def seal(db, capture_id, cache=None):
    """Replace a finished capture's staged payloads with codec blobs and its query.FACTS row; the payload-byte delta.

    Compresses and verifies in a read snapshot, then rechecks the staged rows and writes in one short write
    transaction. Any failure rolls back and leaves the staged rows reading as before. 0 when there is nothing to seal."""
    import codec
    from query import FACTS
    if db.in_transaction:
        raise ValueError("seal needs a connection outside a transaction")
    if [row[0] for row in db.execute("SELECT version FROM capture_meta")] != [2]:
        raise ValueError("seal requires capture schema version 2")
    with snapshot(db):
        staged = _staged(db, capture_id)
        if staged is None:
            return 0
        metadata, response = (json.loads(value or "{}") for value in db.execute(
            "SELECT metadata_json,response_json FROM captures WHERE id=?", (capture_id,)).fetchone())
        body, request = request_body(db, capture_id), None
        if body is not None:
            # The latest earlier request of the same conversation; the strict order keeps the base graph acyclic.
            base_id = (db.execute("""SELECT b.id FROM captures c JOIN captures b
                ON json_extract(b.metadata_json,'$."kiro:conversation_id"')=nullif(json_extract(c.metadata_json,'$."kiro:conversation_id"'),'')
                WHERE c.id=? AND b.request_sha256 IS NOT NULL AND (b.started_utc_ns,b.id)<(c.started_utc_ns,c.id)
                ORDER BY b.started_utc_ns DESC,b.id DESC LIMIT 1""", (capture_id,)).fetchone() or (None,))[0]
            base = None if base_id is None else (cache and cache.get(base_id)) or request_body(db, base_id)
            if base is not None and len(base) < codec.MIN_BASE:
                base_id = base = None
            blob = codec.compress_request(body, base)
            if codec.decompress_request(blob, base) != body:
                raise ValueError("seal mismatch")
            request = (capture_id, base_id, blob)
        blobs = codec.compress_response(content_encoding(response), framing_kind(response, "target" in metadata),
                                        *response_rows(db, capture_id))
    try:
        db.execute("BEGIN IMMEDIATE")
        recheck = _staged(db, capture_id)
        if recheck is None:
            db.rollback()
            return 0
        if recheck != staged:
            raise ValueError("staged rows changed during seal")
        db.execute(f"INSERT INTO capture_facts(capture_id,{','.join(FACTS)}) SELECT c.id,{','.join(FACTS.values())} FROM captures c WHERE c.id=?", (capture_id,))
        if request is not None:
            db.execute("INSERT INTO sealed_requests VALUES (?,?,?)", request)
        db.execute("INSERT INTO sealed_responses VALUES (?,?,?,?)", (capture_id, *blobs))
        db.execute("DELETE FROM chunks WHERE capture_id=?", (capture_id,))
        db.execute("DELETE FROM events WHERE capture_id=?", (capture_id,))
        db.execute("UPDATE captures SET request_gzip=NULL WHERE id=?", (capture_id,))
        delta = payload_bytes(db, capture_id) - staged[-1]
        db.commit()
    except BaseException:
        db.rollback()
        raise
    if cache is not None and body is not None:
        cache.put(capture_id, body)
    return delta

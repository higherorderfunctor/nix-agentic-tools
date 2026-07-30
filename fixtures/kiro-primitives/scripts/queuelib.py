"""Shared mechanics for the mode-F synthetic drain queue.

Import-only. Every ``queue_*.py`` CLI in this directory is a thin argument
parser over the functions here, so the atomicity argument lives in exactly one
place.

WHY PYTHON RATHER THAN BASH
---------------------------
The claim has to be atomic in two senses at once: exactly one racer may win the
marker, and no reader may ever observe a half-written one. Bash's honest
primitives (``mkdir``, ``set -o noclobber``) give the first and not the second,
and ``noclobber`` is a shell option a caller can silently switch off. Python
reaches ``link(2)`` directly, which gives both -- see
:func:`create_exclusive_json`. Nothing else in this fixture needs Python.

FILESYSTEM PRECONDITION
-----------------------
The run root must be on a filesystem that supports hard links, and every
record's temp file is written into the record's own directory so the link never
crosses a device. Local storage satisfies this; so does NFS, where ``link`` is
the recommended exclusive primitive.

THE FOUR THINGS THAT ARE AUTHORITATIVE
--------------------------------------
1. **The claim marker's existence is the claim.** ``items/<id>.json`` carries a
   ``state`` field, but it is never written with the value ``claimed`` --
   claimed-ness is *derived* from the marker by :func:`view_state`. So a stale
   item file cannot hand the same item to two workers.
2. **The admit marker's existence is the admission.** Promotion never rewrites
   the item, which keeps item files writable only by their creator and their
   current holder. That single rule is what the concurrency safety rests on; see
   :func:`admit_proposals` for the race that broke when it did not hold.
3. **The event log is lossless.** Every event is its own file, exclusively
   created (invariant L2: workers never append to a shared log). The
   double-claim detector in ``queue_verify.py`` is reconstructed entirely from
   these files, so a dropped event would read as a clean run.
4. **``results/<id>.json`` is exclusively created.** That makes "reaches a
   terminal state exactly once" a filesystem property rather than a convention.

WHY ``drained`` NEEDS MORE THAN "no ready items"
------------------------------------------------
A late-proposer mints new work *while it is being worked*. If ``drained`` meant
"no ready items", it could go true while a worker still holds the item whose
completion will push a child -- and the consumer, which checks the flag after
each iteration body, would stop and drop that child. So
:func:`refresh_status` requires ``ready == 0`` **and** ``proposed == 0``
**and** ``claimed == 0`` **and** ``orphaned == 0``.

That is exactly the set of states from which new work can still appear, and it
is what makes the flag safe to compute concurrently: pushing requires holding
an unreleased claim (see :func:`push`), so any actor able to mint work is
counted in ``claimed`` or ``orphaned``. A scan that observes all four at zero
has observed a state no actor can leave.
"""

import json
import os
import re
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# Exit codes -- shared so the shell drivers and the Python CLIs agree.
# Borrowed from the reference loop convention: 0 continue, 2 escalate, 1 error.
# --------------------------------------------------------------------------
EXIT_OK = 0
EXIT_ERROR = 1
EXIT_VIOLATION = 2
EXIT_EMPTY = 3
EXIT_ITEM_FAILED = 4
EXIT_INVARIANT = 5

# An id becomes a filename, so it is validated rather than trusted. Chained
# derivation appends `.c<n>` per generation, hence the generous length.
ITEM_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
OWNER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

# `done` and `dead` are the only resting states. `failed` is deliberately not
# one: a failure either returns the item to `ready` (attempts remain) or
# dead-letters it (attempts exhausted), so there is no state an item can sit
# in that is neither claimable nor terminal.
TERMINAL_STATES = ("dead", "done")
ITEM_STATES = ("dead", "done", "proposed", "ready")
VIEW_STATES = ("claimed", "dead", "done", "orphaned", "proposed", "ready")

CLAIM_STRATEGIES = ("exclusive", "read-then-write")

DEFAULT_CONFIG = {
    "dry_threshold": 2,
    "lease_ttl_sec": 30,
    "max_attempts": 3,
    "max_lineage_depth": 3,
    "unit_ms": 200,
}


class QueueError(Exception):
    """A refusal. Always carries a reason a human can act on."""


def cli_main(name, entry, argv=None):
    """Uniform CLI wrapper: a refusal prints one line and exits 1, never a
    traceback. Shared so the six ``queue_*.py`` front ends cannot drift."""
    try:
        return entry(argv)
    except QueueError as error:
        print(f"{name}: {error}", file=sys.stderr)
        return EXIT_ERROR


# --------------------------------------------------------------------------
# Time. Two representations, named so they cannot be confused:
#   *_epoch -- float seconds, the only thing ever compared by code
#   *_iso   -- UTC ISO-8601, for humans reading a record
# --------------------------------------------------------------------------


def now_epoch():
    return time.time()


def iso(epoch=None):
    when = datetime.fromtimestamp(
        now_epoch() if epoch is None else epoch, tz=timezone.utc
    )
    return when.isoformat(timespec="milliseconds").replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------


def admits_dir(root):
    return Path(root) / "admits"


def admit_path(root, item_id):
    return admits_dir(root) / (check_item_id(item_id) + ".json")


def claims_dir(root):
    return Path(root) / "claims"


def claim_dir(root, item_id):
    return claims_dir(root) / check_item_id(item_id)


def config_path(root):
    return Path(root) / "config.json"


def events_dir(root):
    return Path(root) / "events"


def items_dir(root):
    return Path(root) / "items"


def item_path(root, item_id):
    return items_dir(root) / (check_item_id(item_id) + ".json")


def results_dir(root):
    return Path(root) / "results"


def result_path(root, item_id):
    return results_dir(root) / (check_item_id(item_id) + ".json")


def status_path(root):
    return Path(root) / "status.json"


def check_item_id(item_id):
    if not isinstance(item_id, str) or not ITEM_ID_RE.match(item_id):
        raise QueueError(f"refusing unsafe item id: {item_id!r}")
    return item_id


def check_owner(owner):
    if not isinstance(owner, str) or not OWNER_RE.match(owner):
        raise QueueError(f"refusing unsafe owner name: {owner!r}")
    return owner


# --------------------------------------------------------------------------
# Durable writes
# --------------------------------------------------------------------------


# In-progress writes land on this suffix, never `.json`, so no `*.json` glob can
# ever see one. That is not belt-and-braces, it is a bug fix: unlike
# `glob.glob`, `pathlib.Path.glob("*.json")` DOES match a leading-dot filename.
# A `.tmp-XXXX.json` scratch file was therefore listed as a real item -- and
# since the temp already held the complete record, `list_items` returned an item
# whose id had no file yet, and the claimant died on "no such item: s09.c1.c1".
# One branch in 240; found by hunting, not by the predicate, because verify keys
# items by id and the duplicate collapsed. Status counts were double-counting it.
TMP_SUFFIX = ".tmp"


def _dump(obj):
    return json.dumps(obj, indent=2, sort_keys=True) + "\n"


def json_files(directory):
    """Every published ``*.json`` in a directory, excluding in-progress writes.

    Both guards are deliberate: the suffix rule above means there should be
    nothing to skip, and the dotfile filter means an unrelated tool leaving a
    hidden JSON file behind still cannot be mistaken for queue state.
    """
    directory = Path(directory)
    if not directory.is_dir():
        return []
    return sorted(
        path
        for path in directory.glob("*.json")
        if not path.name.startswith(".")
    )


def atomic_write_json(path, obj):
    """Replace ``path`` with ``obj``, atomically.

    A plain ``open(path, "w")`` truncates first, which exposes a window where a
    concurrent reader sees a zero-length file and ``json.load`` raises. Writing
    a sibling temp file and ``os.replace``-ing it (rename(2)) means a reader
    sees either the whole old file or the whole new one.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=TMP_SUFFIX)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(_dump(obj))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def create_exclusive_json(path, obj):
    """Create ``path`` holding ``obj`` iff it does not exist. ``True`` if created.

    This is the whole atomicity story, and it is deliberately NOT the obvious
    an ``os.open`` with ``O_EXCL`` followed by a write. That form is atomic about WHO wins
    but not about WHAT a concurrent reader sees: the name appears the instant
    ``open`` returns, so a reader between the open and the write gets a
    zero-length or half-written record. Measured here as a real failure -- a
    claim marker read mid-write, and a signal delivered inside the ``fsync``
    leaving a marker whose owner nobody knew.

    Writing a complete temp file and then ``os.link``-ing it into place gets
    both properties from one kernel operation: ``link(2)`` fails with ``EEXIST`` if the
    target exists, so of N racers exactly one wins, and the target appears
    already holding the full record. Preconditions: the run root must be on a
    filesystem that supports hard links (it also happens to make this correct on
    NFS, where ``link`` is the recommended exclusive primitive and ``O_EXCL``
    is not). A crash between the write and the link leaves a stray dotfile,
    which no ``*.json`` glob can match -- see TMP_SUFFIX for why that needed
    arranging rather than assuming.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=TMP_SUFFIX)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(_dump(obj))
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(tmp, str(path))
        except FileExistsError:
            return False
        return True
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as exc:
        raise QueueError(f"malformed JSON at {path}: {exc}") from exc


# --------------------------------------------------------------------------
# Events
# --------------------------------------------------------------------------


def emit_event(root, kind, **fields):
    """Append one event as its own file.

    One file per event, never a shared append target (invariant L2). The name
    carries a uuid suffix so two events emitted in the same microsecond by the
    same pid cannot collide -- and the create is still ``O_EXCL``, because a
    dropped event would make a violated run look clean.
    """
    stamp = now_epoch()
    event = {"at_epoch": stamp, "at_iso": iso(stamp), "kind": kind, "pid": os.getpid()}
    event.update(fields)
    name = "{:017.6f}-{:d}-{:s}.json".format(stamp, os.getpid(), uuid.uuid4().hex[:8])
    if not create_exclusive_json(events_dir(root) / name, event):
        raise QueueError(f"event name collision on {name} -- the log is not lossless")
    return event


def read_events(root):
    out = []
    for path in json_files(events_dir(root)):
        event = read_json(path)
        if event is not None:
            out.append(event)
    out.sort(key=lambda e: (e.get("at_epoch", 0.0), e.get("kind", "")))
    return out


# --------------------------------------------------------------------------
# Config and items
# --------------------------------------------------------------------------


def load_config(root):
    cfg = read_json(config_path(root))
    if cfg is None:
        raise QueueError(f"no config.json under {root} -- run queue_init.py first")
    merged = dict(DEFAULT_CONFIG)
    merged.update(cfg)
    return merged


def load_item(root, item_id):
    item = read_json(item_path(root, item_id))
    if item is None:
        raise QueueError(f"no such item: {item_id}")
    return item


def save_item(root, item):
    # The state vocabulary is closed, and a typo in it would present as an item
    # that is silently neither claimable nor terminal -- i.e. as a hang. Cheap
    # enough to check on every write.
    if item.get("state") not in ITEM_STATES:
        raise QueueError(
            f"item {item.get('id')!r} would be saved with state "
            f"{item.get('state')!r}, which is not one of {ITEM_STATES}"
        )
    item["updated_at_iso"] = iso()
    atomic_write_json(item_path(root, item["id"]), item)


def list_items(root):
    items = []
    for path in json_files(items_dir(root)):
        item = read_json(path)
        if item is not None:
            items.append(item)
    items.sort(key=lambda i: (i.get("priority", 0), i["id"]))
    return items


# --------------------------------------------------------------------------
# The work itself -- deterministic, so the fixture measures orchestration
# --------------------------------------------------------------------------


def expected_answer(payload):
    """Sum the inclusive range in ``payload``, by actually iterating it.

    Deliberately not the closed form. A verifier that recomputes this from the
    payload can then tell "the worker ran" from "the worker copied the
    item's ``expected`` field", because the ranges are distinct per item.
    """
    if payload.get("op") != "sum_range":
        raise QueueError(f"unknown payload op: {payload.get('op')!r}")
    total = 0
    for n in range(int(payload["a"]), int(payload["b"]) + 1):
        total += n
    return total


def perform(item, unit_ms):
    """Sleep the item's declared duration, then compute its answer."""
    time.sleep(int(item["duration_units"]) * int(unit_ms) / 1000.0)
    return expected_answer(item["payload"])


# --------------------------------------------------------------------------
# Claims
# --------------------------------------------------------------------------


def gen_name(gen):
    return f"{gen:04d}.json"


def claim_token(item_id, gen):
    return f"{check_item_id(item_id)}#{int(gen)}"


def parse_token(token):
    if not isinstance(token, str) or "#" not in token:
        raise QueueError(f"malformed claim token: {token!r}")
    item_id, _, gen = token.rpartition("#")
    if not gen.isdigit():
        raise QueueError(f"malformed claim token: {token!r}")
    return check_item_id(item_id), int(gen)


def claim_generations(root, item_id):
    gens = []
    for path in json_files(claim_dir(root, item_id)):
        if path.stem.isdigit():
            gens.append(int(path.stem))
    return sorted(gens)


def read_claim(root, item_id, gen):
    return read_json(claim_dir(root, item_id) / gen_name(gen))


def top_claim(root, item_id):
    gens = claim_generations(root, item_id)
    if not gens:
        return None
    return read_claim(root, item_id, gens[-1])


def claim_is_open(claim, now=None):
    """Open == acquired, not released, not yet expired."""
    if claim is None or claim.get("released_at_epoch") is not None:
        return False
    return (now_epoch() if now is None else now) < claim["expires_at_epoch"]


def view_state(root, item, now=None):
    """The item's authoritative state.

    Nothing here trusts a single field, because each fact has exactly one
    trustworthy source:

    * **claimed-ness** comes from the claim marker, never from the item file, so
      a stale item file cannot hand one item to two workers;
    * **terminal-ness** comes from the item file, which for a terminal state is
      only ever written by the holder, after the result is already durable;
    * **whether a proposal is admitted** comes from the ``admits/<id>.json``
      marker, not from
      rewriting the item's ``state``. That is what keeps the admission gate off
      the item file entirely: promoting ``proposed`` -> ``ready`` by rewriting an
      item nobody holds is an unowned read-then-write, and two concurrent
      admitters could then replay a stale ``ready`` over a completed item and
      make it claimable a second time.
    """
    if item.get("state") in TERMINAL_STATES:
        return item["state"]
    now = now_epoch() if now is None else now
    top = top_claim(root, item["id"])
    if top is not None and top.get("released_at_epoch") is None:
        return "claimed" if now < top["expires_at_epoch"] else "orphaned"
    if item.get("state") == "proposed":
        return "ready" if admit_path(root, item["id"]).exists() else "proposed"
    return "ready"


def acquire(root, item_id, owner, strategy="exclusive", unsafe_window_ms=2):
    """Take the lease on one item. ``None`` means "somebody else has it".

    ``strategy`` exists for exactly one reason: ``self-test-queue.sh`` needs a
    positive control proving its double-claim detector can fire. Running the
    control through this same function is the point -- a control that exercised
    a copy of the claim logic would prove nothing about this one.
    ``read-then-write`` must never be selected in a real run, and every caller
    that selects it warns on stderr.
    """
    if strategy not in CLAIM_STRATEGIES:
        raise QueueError(f"unknown claim strategy: {strategy!r}")
    check_owner(owner)
    cfg = load_config(root)
    item = load_item(root, item_id)
    if item.get("state") in TERMINAL_STATES:
        return None

    directory = claim_dir(root, item_id)
    directory.mkdir(parents=True, exist_ok=True)
    gens = claim_generations(root, item_id)
    stolen_from = None
    if gens:
        top = read_claim(root, item_id, gens[-1])
        if top is None:
            raise QueueError(f"unreadable claim {item_id}#{gens[-1]}")
        if claim_is_open(top):
            return None
        if top.get("released_at_epoch") is None:
            # An expired lease. Acquiring the NEXT generation *is* the requeue.
            # It is not a silent reap: the previous holder is named in the new
            # record and in a `claim.stolen_expired_lease` event, and
            # refresh_status keeps reporting the orphan until then.
            stolen_from = {
                "gen": top["gen"],
                "owner": top["owner"],
                "expired_at_epoch": top["expires_at_epoch"],
            }
        nxt = gens[-1] + 1
    else:
        nxt = 0

    # Attempt cap. Checked HERE, after the generation scan proved nothing holds
    # the item, so dead-lettering can never race a live holder's own write
    # (invariant L4). Two concurrent claimants may both dead-letter, which is
    # harmless: the write is idempotent and monotone, ready -> dead only.
    if int(item.get("attempts", 0)) >= int(cfg["max_attempts"]):
        dead_letter(root, item, "max_attempts_exhausted")
        return None

    stamp = now_epoch()
    record = {
        "acquired_at_epoch": stamp,
        "acquired_at_iso": iso(stamp),
        "expires_at_epoch": stamp + float(cfg["lease_ttl_sec"]),
        "gen": nxt,
        "item_id": item_id,
        "outcome": None,
        "owner": owner,
        "pid": os.getpid(),
        "released_at_epoch": None,
        "stolen_from": stolen_from,
        "strategy": strategy,
    }
    target = directory / gen_name(nxt)

    if strategy == "exclusive":
        if not create_exclusive_json(target, record):
            return None
    else:
        # DELIBERATELY BROKEN -- the positive control. `exists()` then write is
        # the TOCTOU shape invariant L1 bans. The sleep only widens an existing
        # window so the control fires reliably; it does not create the race.
        if target.exists():
            return None
        time.sleep(int(unsafe_window_ms) / 1000.0)
        atomic_write_json(target, record)

    # Attempts are bumped after the lease is held, so only the holder writes
    # the item file. A crash in this gap under-counts one attempt; the lease
    # then expires and the item is retried, which is the safe direction.
    item = load_item(root, item_id)
    item["attempts"] = int(item.get("attempts", 0)) + 1
    save_item(root, item)

    if stolen_from is not None:
        emit_event(
            root,
            "claim.stolen_expired_lease",
            gen=nxt,
            item=item_id,
            owner=owner,
            previous=stolen_from,
        )
    emit_event(
        root,
        "claim.acquired",
        attempt=item["attempts"],
        gen=nxt,
        item=item_id,
        owner=owner,
        strategy=strategy,
    )
    return record


def claim_next(root, owner, strategy="exclusive", unsafe_window_ms=2, admit=True):
    """Claim the first claimable item, or return ``None`` (never poll).

    ``None`` is not an error -- invariant L5: an empty claim makes the worker
    RETURN. Re-dispatch is the orchestrator's business, and its stop condition
    is the ``drained`` flag, not an empty claim (see the module docstring).
    """
    if admit:
        admit_proposals(root)
    now = now_epoch()
    for item in list_items(root):
        if view_state(root, item, now) not in ("orphaned", "ready"):
            continue
        record = acquire(
            root,
            item["id"],
            owner,
            strategy=strategy,
            unsafe_window_ms=unsafe_window_ms,
        )
        if record is not None:
            return record
    return None


def validate_claim(root, token, owner=None):
    """Resolve a claim token to its record, refusing anything not live."""
    item_id, gen = parse_token(token)
    record = read_claim(root, item_id, gen)
    if record is None:
        raise QueueError(f"no such claim: {token}")
    if owner is not None and record.get("owner") != owner:
        # An owner mismatch means the marker was overwritten after this caller
        # created it, which only an unsafe claim can do. Recorded as an event
        # before raising, because it is one of the signatures the positive
        # control in self-test-queue.sh counts.
        emit_event(
            root,
            "claim.owner_mismatch",
            asserted_owner=owner,
            gen=gen,
            item=item_id,
            record_owner=record.get("owner"),
        )
        raise QueueError(
            f"claim {token} is held by {record.get('owner')!r}, not {owner!r}"
        )
    if record.get("released_at_epoch") is not None:
        raise QueueError(f"claim {token} is already released")
    gens = claim_generations(root, item_id)
    if gens and gens[-1] != gen:
        # Somebody stole the expired lease. The current holder owns the item;
        # this caller must not write to it.
        raise QueueError(f"claim {token} was superseded by generation {gens[-1]}")
    return item_id, gen, record


def _close_claim(root, item_id, gen, outcome, note=None):
    record = read_claim(root, item_id, gen)
    stamp = now_epoch()
    record["outcome"] = outcome
    record["released_at_epoch"] = stamp
    record["released_at_iso"] = iso(stamp)
    if note is not None:
        record["note"] = note
    atomic_write_json(claim_dir(root, item_id) / gen_name(gen), record)
    emit_event(
        root,
        "claim.released",
        gen=gen,
        item=item_id,
        outcome=outcome,
        owner=record.get("owner"),
    )
    return record


def dead_letter(root, item, reason):
    item["state"] = "dead"
    item["dead_letter_reason"] = reason
    save_item(root, item)
    emit_event(root, "item.dead_lettered", item=item["id"], reason=reason)
    return item


def release(root, token, outcome, answer=None, reason=None, owner=None):
    """Close a claim. ``outcome`` is done | failed | abandoned.

    ``done`` writes ``results/<id>.json`` with ``O_EXCL`` *before* the item is
    marked terminal, so a crash between the two leaves the lease held and the
    retry can recover. That ordering is why the collision handling below has to
    distinguish a recovery from a genuine double completion rather than
    treating every ``EEXIST`` as a violation.
    """
    if outcome not in ("abandoned", "done", "failed"):
        raise QueueError(f"unknown outcome: {outcome!r}")
    item_id, gen, record = validate_claim(root, token, owner=owner)
    cfg = load_config(root)
    item = load_item(root, item_id)
    verdict = {"item": item_id, "gen": gen, "outcome": outcome, "violation": None}

    if outcome == "done":
        if answer is None:
            raise QueueError("outcome=done requires an answer")
        payload = {
            "answer": answer,
            "at_epoch": now_epoch(),
            "at_iso": iso(),
            "duration_units": item["duration_units"],
            "gen": gen,
            "item_id": item_id,
            "owner": record["owner"],
        }
        if not create_exclusive_json(result_path(root, item_id), payload):
            existing = read_json(result_path(root, item_id))
            same_holder = existing.get("owner") == record["owner"]
            if not same_holder or existing.get("answer") != answer:
                # Two different holders completed the same item, or the same
                # holder produced two different answers. Either way the atomic
                # claim did not hold -- this is the signature the positive
                # control is looking for.
                verdict["violation"] = "double_completion"
                emit_event(
                    root,
                    "item.double_completion",
                    existing=existing,
                    gen=gen,
                    item=item_id,
                    owner=record["owner"],
                )
                _close_claim(root, item_id, gen, "violation", note="double_completion")
                return verdict
            if existing.get("gen") != gen:
                emit_event(
                    root,
                    "item.result_recovered",
                    existing_gen=existing.get("gen"),
                    gen=gen,
                    item=item_id,
                )
        item["state"] = "done"
        item["answer"] = answer
        save_item(root, item)
        _close_claim(root, item_id, gen, "done")
        emit_event(root, "item.done", answer=answer, gen=gen, item=item_id)
        return verdict

    # failed / abandoned: the lease is released either way. `abandoned` is what
    # a SIGTERM or an exception releases -- the item goes straight back to
    # claimable without burning the failure budget beyond the attempt already
    # counted at acquire time (invariant L7).
    _close_claim(root, item_id, gen, outcome, note=reason)
    if int(item.get("attempts", 0)) >= int(cfg["max_attempts"]):
        dead_letter(root, item, reason or f"{outcome}_attempts_exhausted")
        verdict["requeued"] = False
    else:
        item["state"] = "ready"
        item["last_failure"] = reason
        save_item(root, item)
        emit_event(root, "item.requeued", item=item_id, outcome=outcome, reason=reason)
        verdict["requeued"] = True
    return verdict


# --------------------------------------------------------------------------
# Proposal gate: depth is computed here, never supplied
# --------------------------------------------------------------------------


def _build_child(parent, spec, record, ordinal, depth, cap):
    """The complete child record. Built before the file exists, never after.

    An earlier version reserved the id first by creating a placeholder item and
    filling it in afterwards. That is a bug, and a nasty one: for the width of
    the fill-in, ``items/`` held an item with no ``payload`` and no
    ``duration_units`` whose ``state`` was neither terminal nor ``proposed``, so
    :func:`view_state` called it ``ready`` and a concurrent claimant took it and
    died on a ``KeyError``. Observed in 4 of 6 twelve-claimant runs. The fix is
    structural: build the whole record first, then publish it in a single
    exclusive create, so a partially-constructed item cannot exist at all.
    """
    remaining = int(spec.get("chain", 1)) - 1
    units = int(spec.get("duration_units", 1))
    start = int(parent["payload"]["b"]) + 100 * ordinal
    payload = {"a": start, "b": start + units + 2, "op": "sum_range"}
    child = {
        "answer": None,
        "attempts": 0,
        "created_at_iso": iso(),
        "dead_letter_reason": None,
        "derived_from": parent["id"],
        "duration_units": units,
        "expected": expected_answer(payload),
        "id": f"{parent['id']}.c{ordinal}",
        "kind": "derived",
        "lineage_depth": depth,
        "payload": payload,
        "priority": depth,
        "proposed_by": record["owner"],
        "proposes": (
            {"chain": remaining, "duration_units": units} if remaining > 0 else None
        ),
        "state": "proposed",
        "updated_at_iso": iso(),
    }
    if depth > cap:
        child["dead_letter_reason"] = (
            f"lineage_depth {depth} exceeds max_lineage_depth {cap}"
        )
        child["proposes"] = None
        child["state"] = "dead"
    return child


def push(root, token, derived_from, owner=None):
    """Enqueue work derived from the caller's own claimed item.

    The caller supplies ``{claim, derived_from}`` and nothing else. In
    particular it supplies neither the depth nor the payload:

    * **Depth** is read off the parent and incremented here. A push whose
      resulting depth would exceed ``max_lineage_depth`` is refused and
      dead-lettered with a reason, which makes over-deep derivation
      structurally impossible instead of prompt-discouraged.
    * **Payload** comes from the parent's own ``proposes`` declaration. A
      worker cannot author claimable work (invariant L6); it can only report
      that the work its item declared has become real.
    * ``derived_from`` must be the claimed item. Allowing a worker to name some
      other, shallower parent would let it dodge the depth cap -- so a mismatch
      is a refusal, and the redundancy with the token acts as a checksum.

    Accepted work lands as ``proposed``, not ``ready``. :func:`admit_proposals`
    is the only thing that mints claimable work.
    """
    item_id, gen, record = validate_claim(root, token, owner=owner)
    if derived_from != item_id:
        raise QueueError(
            f"derived_from={derived_from!r} does not match the claimed item "
            f"{item_id!r} -- a worker may only derive from what it holds"
        )
    cfg = load_config(root)
    parent = load_item(root, item_id)
    spec = parent.get("proposes")
    if not spec:
        raise QueueError(f"item {item_id} declares no proposal -- nothing to push")

    depth = int(parent.get("lineage_depth", 0)) + 1
    cap = int(cfg["max_lineage_depth"])

    # The ordinal walk resolves a concurrent push from a retried parent: the id
    # is not taken until the COMPLETE record is published, and publication is a
    # single exclusive create, so the loser simply moves to the next ordinal.
    child = None
    for ordinal in range(1, 1000):
        candidate = _build_child(parent, spec, record, ordinal, depth, cap)
        if create_exclusive_json(item_path(root, candidate["id"]), candidate):
            child = candidate
            break
    if child is None:
        raise QueueError(f"cannot allocate a child id under {item_id}")

    if child["state"] == "dead":
        emit_event(
            root,
            "push.refused_over_cap",
            depth=depth,
            item=child["id"],
            max_lineage_depth=cap,
            parent=item_id,
        )
        return {
            "accepted": False,
            "cap": cap,
            "id": child["id"],
            "lineage_depth": depth,
            "reason": child["dead_letter_reason"],
        }

    emit_event(
        root,
        "push.accepted",
        depth=depth,
        item=child["id"],
        owner=record["owner"],
        parent=item_id,
    )
    return {"accepted": True, "cap": cap, "id": child["id"], "lineage_depth": depth}


def admit_proposals(root):
    """The gate: make ``proposed`` items claimable by creating an admit marker.

    The MARKER is the promotion, not a rewrite of the item's ``state``. An
    earlier version flipped ``proposed`` -> ``ready`` in the item file, which is
    an unowned read-then-write and races two ways: two admitters can both be
    holding a stale ``proposed`` copy, and one can then replay ``ready`` over an
    item a third process has since completed -- resurrecting it for a second
    claim. Creating ``admits/<id>.json`` exclusively is idempotent, needs no
    read, and leaves item files writable only by their creator and their holder.

    The depth re-check is defense in depth: :func:`push` already refuses over-cap
    work, so a ``proposed`` item above the cap means the cap moved mid-run. That
    is a misconfiguration rather than a work item, so it raises instead of being
    quietly dead-lettered -- a run whose cap moved under it should stop.
    """
    cfg = load_config(root)
    cap = int(cfg["max_lineage_depth"])
    admitted = []
    for item in list_items(root):
        if item.get("state") != "proposed":
            continue
        if admit_path(root, item["id"]).exists():
            continue
        depth = int(item.get("lineage_depth", 0))
        if depth > cap:
            emit_event(
                root,
                "admit.refused_over_cap",
                depth=depth,
                item=item["id"],
                max_lineage_depth=cap,
            )
            raise QueueError(
                f"item {item['id']} sits at lineage_depth {depth} but the cap is "
                f"now {cap} -- max_lineage_depth was lowered mid-run"
            )
        marker = {
            "at_epoch": now_epoch(),
            "at_iso": iso(),
            "depth": depth,
            "item": item["id"],
        }
        if create_exclusive_json(admit_path(root, item["id"]), marker):
            emit_event(root, "item.admitted", depth=depth, item=item["id"])
            admitted.append(item["id"])
    return admitted


# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------


def refresh_status(root, write=True):
    """Compute the queue status and write ``status.json``.

    Writing happens in the SAME operation as the observation, on purpose: the
    consumer checks the flag after each iteration body, so a status computed
    now and written later could report a queue state that has already moved.

    A zero denominator is not drained. An empty or missing ``items/`` would
    otherwise read as "all done", which is exactly how a broken enumeration
    presents -- so it reports a refusal instead and leaves the flag false.

    CONCURRENT PUBLICATION IS LAST-WRITER-WINS, AND THAT IS SAFE. Many branches
    call this at once, so a scan that finished earlier can land its write later
    and republish ``false`` over a ``true``. The dangerous direction -- a
    spurious ``true`` -- cannot happen, because minting work requires an
    unreleased claim and that is counted; the flag can therefore only be true of
    a state no actor could have left. A spurious ``false`` costs one extra
    iteration and is corrected by the next scan, so the flag converges.
    """
    cfg = load_config(root)
    now = now_epoch()
    counts = {state: 0 for state in VIEW_STATES}
    orphans = []
    in_flight = []
    for item in list_items(root):
        state = view_state(root, item, now)
        counts[state] += 1
        top = top_claim(root, item["id"])
        if state == "orphaned":
            orphans.append(
                {
                    "expired_ago_sec": round(now - top["expires_at_epoch"], 3),
                    "gen": top["gen"],
                    "item": item["id"],
                    "owner": top["owner"],
                    "pid": top.get("pid"),
                }
            )
        elif state == "claimed":
            orphans_ttl = round(top["expires_at_epoch"] - now, 3)
            in_flight.append(
                {
                    "gen": top["gen"],
                    "item": item["id"],
                    "owner": top["owner"],
                    "ttl_sec": orphans_ttl,
                }
            )
    total = sum(counts.values())
    refusal = None
    if total == 0:
        refusal = "no items found -- refusing to report drained on a zero denominator"
    drained = total > 0 and not (
        counts["claimed"] or counts["orphaned"] or counts["proposed"] or counts["ready"]
    )
    status = {
        "counts": counts,
        "drained": drained,
        "in_flight": sorted(in_flight, key=lambda entry: entry["item"]),
        "max_lineage_depth": cfg["max_lineage_depth"],
        "orphans": sorted(orphans, key=lambda entry: entry["item"]),
        "profile": cfg.get("profile"),
        "refusal": refusal,
        "total": total,
        "updated_at_epoch": now,
        "updated_at_iso": iso(now),
    }
    if write:
        atomic_write_json(status_path(root), status)
    return status


def lineage_forest(root):
    """Group items by parent for a ``--tree`` rendering."""
    items = {item["id"]: item for item in list_items(root)}
    children = {}
    roots = []
    for item in sorted(items.values(), key=lambda i: i["id"]):
        parent = item.get("derived_from")
        if parent and parent in items:
            children.setdefault(parent, []).append(item["id"])
        else:
            roots.append(item["id"])
    return items, children, roots

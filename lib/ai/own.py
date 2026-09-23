"""Reconcile every artifact a generation OWNS, through one of two containers.

One plan, applied once: an ordered list of targets, each naming a container
(`codec`), where the container lives relative to the backend root (`path`), the
ledger recording what the last run owned (`ledger`, relative to the state root)
and the units this generation declares. Everything a caller can vary is data
inside that JSON plan, so no name, mode or byte of content is ever interpolated
into a shell word.

Two containers, because a directory leaf can be a symlink, a FIFO or a file
someone edited while a document leaf cannot, and because a container whose
units are whole files can back one up and must state each unit's mode, while
one whose units are leaves of a shared byte stream can back up nothing and
states at most one mode, for the single file every leaf shares:

    DirContainer   a directory     units are filenames    witness: sha256
    DocContainer   one document    units are key tuples    witness: the address

Both legacy ledger formats are read and written at their existing paths and
bytes (TSV for a directory, JSON v1 for a document). That is load-bearing, not
inertia: home-manager rollback runs an OLDER generation's script against
today's on-disk ledger, so a unified format would either fail activation (the
old Python reader raises on an unknown manifest) or silently prune nothing (the
old bash reader treats a JSON line as a filename). Keeping both formats costs
one reader and one writer each and buys zero migration code.
"""

# cspell:ignore fchmod fdopen

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import contextlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, MutableMapping
from pathlib import Path, PurePosixPath
from typing import Any

CODECS = ("dir", "json", "toml")
CONTENT_FIELDS = ("run", "store", "text")
DEFAULT_DIR_MODE = "0444"
LEDGER_VERSION = 1
NEW_FILE_MODE = 0o600
# State-dir-wide, at the path the generated bash materializer already locks.
# That is a live compatibility contract rather than a naming accident: while
# the migration is in flight a devenv shell can run one surface through this
# program and another through the old script concurrently, and the reserved
# `.nat-tmp.` sweep below deliberately owns that namespace across every surface
# sharing a backend. Two lock paths would let two sweeps run at once and delete
# each other's live temporary files.
LOCK = ("materialize", "lock")
# A target's NATIVE writer lock is the proper-lockfile protocol pi uses around
# trust.json (dist/core/trust-manager.js acquireTrustLockSync): a directory at
# `<document>.lock`, created with mkdir, removed on release, and judged dead
# once its mtime is older than the library's default `stale` of 10 s. A holder
# that stops refreshing it for that long is gone, so this run breaks it too.
FOREIGN_LOCK_STALE = 10.0
FOREIGN_LOCK_WAIT = 10.0

# The clobber guard, transcribed arm by arm from the shell it replaced so the
# two can be diffed side by side. The citations are line numbers in that file,
# which is deleted -- read it with
# `git show 7b9adc2d:lib/ai/materialize.nix` (`nat_mat_write` inside
# mkWriteCore, and the loop body of mkPruneCore).
# The ORDER of the tests is part of the guard: `-L` is answered before any
# content comparison, because cmp-skipping an identical-content symlink would
# reinstate the Kiro v3 skips-symlinks defect.
#
# (is_symlink, exists, is_regular, witness) -> action
WRITE_ARMS = {
    (True, None, None, None): "replace",  # :374-378 a symlink is never user content
    (False, False, None, None): "fresh",  # :379-380
    (False, True, False, None): "error",  # :381-385 FIFO/dir/device: loud, never clobbered
    (False, True, True, "match"): "skip_if_equal",  # :388-395
    (False, True, True, "mismatch"): "backup_overwrite",  # :396-398
    (False, True, True, "unrecorded"): "backup_adopt",  # :399-402
}
# (is_symlink, exists, is_regular) -> action
REMOVE_ARMS = {
    (True, None, None): "unlink",  # :320-322 old delivery, remove
    (False, False, None): "gone",  # :323-324 already gone
    (False, True, False): "error",  # :325-327 leave it in place
    (False, True, True): "backup_if_edited",  # :328-335
}


class Conflict(Exception):
    """A target this generation must not clobber. Loud, and never fatal alone.

    The run finishes, the ledger records what did land, and only then does the
    program fail: a conflict on one unit must not strand the others, and it
    must not leave a ledger claiming a file this run refused to touch.
    """


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--phase", choices=("all", "prune"), default="all")
    parser.add_argument("--verify", action="store_true")
    return parser.parse_args()


def require_env(name: str) -> Path:
    value = os.environ.get(name)
    if not value or not value.startswith("/"):
        raise ValueError(f"{name} must be set to an absolute path")
    return Path(value)


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def witness_state(disk: str, previous: str | None) -> str:
    if not previous:
        return "unrecorded"
    return "match" if disk == previous else "mismatch"


# ── Content resolution ──────────────────────────────────────────────


def resolve(content: Mapping[str, Any], bash: str) -> bytes:
    """Resolve one content record to bytes.

    Renderers run HERE, before any container is opened and before the lock is
    taken, so a failing renderer leaves every config file and every ledger
    byte-identical and does not even create the state directory. The rendered
    bytes buffer in memory in a child process: they never reach the calling
    shell's environment and never land in a temporary file a concurrent sweep
    could delete, which is why the old on-disk render buffer and its ERR trap
    have no counterpart here.

    `bash` is the STORE PATH from the plan, never a PATH lookup: an activation
    or shell-entry environment can arrive with a hostile or empty PATH, and a
    renderer is the one place this program runs code that a plan's closure is
    supposed to pin.
    """
    fields = [field for field in CONTENT_FIELDS if field in content]
    if len(fields) != 1:
        raise ValueError(f"content must set exactly one of {', '.join(CONTENT_FIELDS)}")
    if fields[0] == "text":
        return content["text"].encode("utf-8")
    if fields[0] == "store":
        return Path(content["store"]).read_bytes()
    try:
        finished = subprocess.run(
            [bash, "-c", content["run"]], check=True, capture_output=True
        )
    except subprocess.CalledProcessError as failure:
        detail = failure.stderr.decode("utf-8", "replace").strip()
        raise ValueError(f"renderer exited {failure.returncode}: {detail}") from None
    return finished.stdout


def desired_leaves(value: Mapping[str, Any]) -> list[tuple[tuple[str, ...], Any]]:
    """Flatten a declared document into the exact leaf paths it owns."""
    leaves: list[tuple[tuple[str, ...], Any]] = []

    def walk(path: tuple[str, ...], item: Any) -> None:
        if isinstance(item, Mapping):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ValueError("declared object keys must be strings")
                walk((*path, key), child)
            return
        if not path:
            raise ValueError("declared settings must be an object")
        leaves.append((path, item))

    walk((), value)
    return leaves


def units_of(target: Mapping[str, Any], bash: str) -> list[tuple[Any, Any]]:
    """Resolved `(address, unit)` pairs for one target."""
    if target["codec"] == "dir":
        return [
            (
                address,
                {
                    "content": resolve(record, bash),
                    "mode": record.get("mode", DEFAULT_DIR_MODE),
                },
            )
            for address, record in sorted(target["units"].items())
        ]
    if not target["units"]:
        return []
    declared = json.loads(resolve(target["units"], bash).decode("utf-8"))
    if not isinstance(declared, Mapping):
        raise ValueError(f"declared settings must be an object for {target['path']}")
    return desired_leaves(declared)


# ── Writing ─────────────────────────────────────────────────────────


def atomic_write(path: Path, content: bytes, mode: int) -> None:
    """Replace a file atomically without ever following its destination link."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.nat-tmp.",
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(handle, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def write_if_changed(
    path: Path, content: bytes, mode: int, declared: int | None = None
) -> None:
    """Preserve an existing regular file's mode; use `mode` for a new one.

    A `declared` mode overrides both halves, and a document target is the only
    thing that may state one. It is imposed on every write -- create, adopt,
    rewrite -- and on the run where the bytes did not move, which is the arm
    that carries the real caller: kiro's merge target must re-narrow a file an
    earlier overwrite generation published read-only, and the run that has to
    do it usually has no other work. Absent a declared mode this never changes
    a mode at all, which is what the ledger writers below rely on.
    """
    is_symlink = path.is_symlink()
    if declared is not None:
        mode = declared
    if path.exists() and not is_symlink:
        if not path.is_file():
            raise ValueError(f"refusing to replace non-regular file {path}")
        current = path.read_bytes()
        if declared is None:
            mode = stat.S_IMODE(path.stat().st_mode)
        if current == content:
            if declared is not None:
                # Impose the mode, publish nothing, keep the mtime -- the
                # directory codec's skip arm, for the one file a document is.
                path.chmod(mode)
            return
    elif not path.exists() and is_symlink:
        raise ValueError(f"refusing to replace dangling symlink {path}")

    atomic_write(path, content, mode)


def sweep(directory: Path) -> None:
    """Delete stale reserved temporaries — the ONE non-ledger deletion class.

    The INFIX, not the name shape, is the safety proof: a bare `.<name>.*`
    pattern would eat user dotfiles (a vim `.foo.md.swp`, a `.a.md.notes`),
    whereas no declarable unit address carries `.nat-tmp.` (own.nix bars a
    dot-prefixed address) and essentially no user file does either.
    `tempfile` plus `finally` already covers every normal and exceptional
    exit, so this only collects what SIGKILL leaked -- and in `.kiro/hooks/` a
    leaked dotfile is a file Kiro's scan may load. Both containers sweep, and
    both sweep their ledger's directory too: a leaked sibling of `.claude.json`
    or of `settings/mcp.json` is a half-written copy of that document, which
    can hold a decrypted credential url, and nothing else would ever collect
    it.
    """
    for leftover in directory.glob(".*.nat-tmp.*"):
        if leftover.is_file() and not leftover.is_symlink():
            leftover.unlink()


# ── Containers ──────────────────────────────────────────────────────


class DirContainer:
    """A directory whose units are whole files."""

    def __init__(self, path: Path, relative: PurePosixPath, ledger: Path) -> None:
        self.path = path
        self.relative = relative
        # Backups keep the path the bash writer used (`<slug>.bak` beside the
        # manifest) so a user who already has one finds the next one with it.
        self.backups = ledger.with_suffix(".bak")
        path.mkdir(parents=True, exist_ok=True)
        sweep(path)
        sweep(ledger.parent)

    @staticmethod
    def stale_order(addresses: set[str]) -> list[str]:
        return sorted(addresses)

    def released_path(self, address: str) -> str:
        """The path a co-owning target could claim instead."""
        return str(self.relative / address)

    def backup(self, address: str, reason: str, action: str) -> None:
        self.backups.mkdir(parents=True, exist_ok=True)
        # mkstemp guarantees uniqueness even for same-second backups of the
        # same file (the epoch is kept so backups sort by time); copy2 then
        # stamps the source's mode and times onto the reserved path.
        handle, copy = tempfile.mkstemp(
            dir=self.backups, prefix=f"{address}.{int(time.time())}."
        )
        os.close(handle)
        shutil.copy2(self.path / address, copy)
        print(
            f"WARNING: own: {reason}; backed up to {self.backups}; {action}",
            file=sys.stderr,
        )

    def assert_unit(self, address: str, unit: Mapping[str, Any], previous: str | None) -> str:
        target = self.path / address
        mode = int(unit["mode"], 8)
        content = unit["content"]
        current: bytes | None = None
        if target.is_symlink():
            arm = WRITE_ARMS[True, None, None, None]
        elif not target.exists():
            arm = WRITE_ARMS[False, False, None, None]
        elif not target.is_file():
            arm = WRITE_ARMS[False, True, False, None]
        else:
            current = target.read_bytes()
            arm = WRITE_ARMS[False, True, True, witness_state(digest(current), previous)]

        if arm == "error":
            raise Conflict(
                f"{target} is not a regular file or symlink; refusing to clobber"
            )
        if arm == "skip_if_equal" and current == content:
            # Ours and unchanged: impose the mode, publish nothing, keep the
            # mtime. This arm is only reachable with a recorded witness, and
            # it is already the witness of what is on disk.
            target.chmod(mode)
            return previous
        if arm == "backup_adopt":
            self.backup(address, f"{target} existed but was not managed", "adopting")
        elif arm == "backup_overwrite":
            self.backup(
                address,
                f"{target} was edited since it was materialized",
                "overwriting",
            )
        atomic_write(target, content, mode)
        return digest(content)

    def remove(self, address: str, previous: str | None) -> None:
        target = self.path / address
        if target.is_symlink():
            arm = REMOVE_ARMS[True, None, None]
        elif not target.exists():
            arm = REMOVE_ARMS[False, False, None]
        elif not target.is_file():
            arm = REMOVE_ARMS[False, True, False]
        else:
            arm = REMOVE_ARMS[False, True, True]

        if arm == "error":
            raise Conflict(
                f"{target} is not a regular file or symlink; leaving it in place"
            )
        if arm == "gone":
            return
        if arm == "backup_if_edited" and digest(target.read_bytes()) != previous:
            self.backup(
                address, f"{target} was edited since it was materialized", "removing"
            )
        target.unlink()

    def commit(self, retiring: bool = False) -> None:
        """Nothing to do: every unit was published atomically on its own."""


class DocContainer:
    """One JSON or TOML document whose units are its owned leaves."""

    def __init__(
        self,
        path: Path,
        relative: PurePosixPath,
        codec: str,
        ledger: Path,
        mode: int | None = None,
    ) -> None:
        self.path = path
        self.relative = relative
        # Kept only to sweep its directory at commit; a document's ledger is
        # read and written by the driver, never by the container.
        self.ledger = ledger
        # The mode the document must carry, when its target states one. A
        # leaf cannot have a mode of its own -- every one of them lives in the
        # same file -- but the file can, and one caller needs it.
        self.mode = mode
        if codec == "json":
            self.parse: Callable[[str], Any] = json.loads
            self.serialize: Callable[[Any], str] = (
                lambda document: json.dumps(document, indent=2) + "\n"
            )
            empty: Callable[[], MutableMapping[str, Any]] = dict
            self.new_table: Callable[[], MutableMapping[str, Any]] = dict
        else:
            # JSON callers need only the standard library. Keep the TOML
            # dependency lazy so their activation closure never carries it.
            import tomlkit

            self.parse = tomlkit.parse
            self.serialize = tomlkit.dumps
            empty = tomlkit.document
            self.new_table = tomlkit.table

        # Parse before the first write. A malformed native edit must fail
        # closed, preserving the original bytes.
        if path.exists() or path.is_symlink():
            self.document = self.parse(path.read_text(encoding="utf-8"))
        else:
            self.document = empty()
        if not isinstance(self.document, MutableMapping):
            raise ValueError(f"settings must be an object at {path}")

    @staticmethod
    def stale_order(addresses: set[tuple[str, ...]]) -> list[tuple[str, ...]]:
        # Deepest first, so scalar/table transitions are deterministic and
        # empty-parent pruning never reaches a table with a live sibling.
        return sorted(addresses, key=lambda address: (-len(address), address))

    def released_path(self, address: tuple[str, ...]) -> None:
        """A leaf is not a whole file: there is nothing to hand to a co-owner."""
        return None

    def assert_unit(
        self, address: tuple[str, ...], unit: Any, previous: None
    ) -> None:
        """Set one owned leaf, replacing an incompatible scalar/table shape."""
        current = self.document
        for segment in address[:-1]:
            child = current.get(segment)
            if not isinstance(child, MutableMapping):
                child = self.new_table()
                current[segment] = child
            current = child
        current[address[-1]] = unit

    def remove(self, address: tuple[str, ...], previous: None) -> None:
        """Delete one retired leaf and only the empty parent tables it leaves."""
        parents: list[tuple[MutableMapping[str, Any], str]] = []
        current = self.document
        for segment in address[:-1]:
            child = current.get(segment)
            if not isinstance(child, MutableMapping):
                return
            parents.append((current, segment))
            current = child

        if address[-1] not in current:
            return
        del current[address[-1]]

        for parent, segment in reversed(parents):
            child = parent.get(segment)
            if isinstance(child, MutableMapping) and not child:
                del parent[segment]
            else:
                break

    def commit(self, retiring: bool = False) -> None:
        """One write of the whole document, or none when nothing moved.

        The document lands before its ledger. If the run dies between the two
        atomic replacements the older ledger makes the next one repeat safe,
        idempotent deletes and sets rather than treating an owned leaf as
        unowned.

        `retiring` is a target that declares nothing any more. When its
        retraction leaves the document serializing to nothing but an empty
        object, every byte in it was ours, so the file goes rather than
        staying behind as `{}`. A TOML comment the user added survives
        serialization and keeps the file. An empty document is
        not inert everywhere: Kimchi fills its permission scalars' defaults
        for any project file that exists, so a leftover `{}` would keep
        overriding the user's `defaultMode` after the declaration is gone
        (src/extensions/permissions/config.ts:56-60,98-101). A symlink is
        someone else's publication and is left alone.
        """
        if retiring and self.serialize(self.document).strip() in ("", "{}"):
            sweep(self.path.parent)
            sweep(self.ledger.parent)
            if self.path.is_file() and not self.path.is_symlink():
                self.path.unlink()
            return
        # The reserved sweep, for the two directories this container writes
        # into. HERE rather than in the constructor, which DirContainer can use
        # because only its constructor runs under the lock: a document is also
        # opened by the pre-lock parse, and sweeping there could delete a
        # concurrent run's LIVE temporary -- the hazard the single lock path
        # exists to prevent.
        sweep(self.path.parent)
        sweep(self.ledger.parent)
        write_if_changed(
            self.path,
            self.serialize(self.document).encode(),
            NEW_FILE_MODE,
            self.mode,
        )


def open_container(root: Path, target: Mapping[str, Any], ledger: Path):
    relative = PurePosixPath(target["path"])
    if target["codec"] == "dir":
        return DirContainer(root / relative, relative, ledger)
    declared = target["units"].get("mode")
    return DocContainer(
        root / relative,
        relative,
        target["codec"],
        ledger,
        None if declared is None else int(declared, 8),
    )


# ── Ledgers ─────────────────────────────────────────────────────────


def read_dir_ledger(path: Path) -> dict[str, str] | None:
    """Read the TSV manifest (`<name>\\t<sha256>` per line)."""
    if not path.exists() and not path.is_symlink():
        return None
    recorded: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        name, _, witness = line.partition("\t")
        if not name:
            continue
        # The bash reader REFUSED such an entry too rather than deleting it
        # (7b9adc2d:lib/ai/materialize.nix:312-317), which is why own.nix bars a
        # traversing or dot-prefixed unit address: one this reader skips could
        # be written and never retracted.
        if "/" in name or name.startswith("."):
            print(
                f"WARNING: own: ignoring suspicious ledger entry '{name}' in {path}",
                file=sys.stderr,
            )
            continue
        recorded[name] = witness
    return recorded


def write_dir_ledger(path: Path, written: Mapping[str, str]) -> None:
    body = "".join(f"{name}\t{written[name]}\n" for name in sorted(written))
    write_if_changed(path, body.encode("utf-8"), NEW_FILE_MODE)


def read_doc_ledger(path: Path) -> dict[tuple[str, ...], None] | None:
    """Read and strictly validate the v1 JSON manifest before touching config."""
    if not path.exists() and not path.is_symlink():
        return None

    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != LEDGER_VERSION:
        raise ValueError(f"unsupported managed-path manifest at {path}")

    paths = raw.get("managed_paths")
    if not isinstance(paths, list):
        raise ValueError(f"invalid managed-path manifest at {path}")

    recorded: dict[tuple[str, ...], None] = {}
    for item in paths:
        if (
            not isinstance(item, list)
            or not item
            or not all(isinstance(segment, str) for segment in item)
        ):
            raise ValueError(f"invalid managed path in {path}")
        if tuple(item) in recorded:
            raise ValueError(f"duplicate managed path in {path}")
        recorded[tuple(item)] = None
    return recorded


def write_doc_ledger(path: Path, written: Mapping[tuple[str, ...], None]) -> None:
    body = {
        "managed_paths": [list(address) for address in sorted(written)],
        "version": LEDGER_VERSION,
    }
    write_if_changed(
        path, (json.dumps(body, indent=2, sort_keys=True) + "\n").encode("utf-8"), NEW_FILE_MODE
    )


LEDGER_FORMATS = {
    "dir": (read_dir_ledger, write_dir_ledger),
    "doc": (read_doc_ledger, write_doc_ledger),
}


def ledger_format(codec: str):
    return LEDGER_FORMATS["dir" if codec == "dir" else "doc"]


def ledger_path(state: Path, target: Mapping[str, Any]) -> Path:
    return state / target["ledger"]


def write_ledger(codec: str, path: Path, written: Mapping[Any, Any]) -> None:
    if not written:
        # No ledger means this target owns nothing -- the equality that lets
        # retirement collapse into an ordinary reconcile.
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    ledger_format(codec)[1](path, written)


def acquire_foreign(path: Path) -> None:
    """Take one native writer's mkdir lock, breaking it only once stale."""
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + FOREIGN_LOCK_WAIT
    while True:
        try:
            path.mkdir()
            return
        except FileExistsError:
            pass
        try:
            age = time.time() - path.lstat().st_mtime
        except FileNotFoundError:
            continue
        if age > FOREIGN_LOCK_STALE:
            with contextlib.suppress(FileNotFoundError):
                path.rmdir()
            continue
        if time.monotonic() >= deadline:
            raise ValueError(
                f"{path} is still held by its native writer after "
                f"{FOREIGN_LOCK_WAIT:.0f}s"
            )
        time.sleep(0.02)


@contextlib.contextmanager
def foreign_locks(paths: list[Path]):
    """Hold every native writer lock in `paths`, released in reverse order."""
    held: list[Path] = []
    try:
        for path in paths:
            acquire_foreign(path)
            held.append(path)
        yield
    finally:
        for path in reversed(held):
            with contextlib.suppress(FileNotFoundError):
                path.rmdir()


# ── Plan ────────────────────────────────────────────────────────────


def check_relative(label: str, value: str) -> None:
    candidate = PurePosixPath(value)
    if not value or candidate.is_absolute() or {"", ".", ".."} & set(candidate.parts):
        raise ValueError(f"{label} must be a relative path that does not traverse: '{value}'")


def load_plan(path: Path) -> Mapping[str, Any]:
    """Load and validate the plan. Every rejection here is also an eval error
    in own.nix; this is the backstop for a hand-written or stale plan."""
    plan = json.loads(path.read_text(encoding="utf-8"))
    targets = plan.get("targets")
    if not isinstance(targets, list):
        raise ValueError(f"plan must declare a list of targets at {path}")
    bash = plan.get("bash")
    if not isinstance(bash, str) or not bash.startswith("/"):
        raise ValueError(f"plan must name an absolute bash for renderers at {path}")
    ledgers: set[str] = set()
    claimed: set[str] = set()
    for target in targets:
        missing = [field for field in ("codec", "ledger", "path", "units") if field not in target]
        if missing:
            raise ValueError(f"target is missing {', '.join(missing)}: {target!r}")
        if target["codec"] not in CODECS:
            raise ValueError(
                f"unknown codec '{target['codec']}' for {target['path']}"
            )
        check_relative("target path", target["path"])
        # LIVE targets only: a target declaring nothing RELEASES its path
        # rather than claiming it, which is what the retraction rule below
        # turns the overwrite/merge handover into. Two live targets on one path
        # each publish over the other and back the other's file up as a hand
        # edit, once per generation.
        if target["units"]:
            path = str(PurePosixPath(target["path"]))
            if path in claimed:
                raise ValueError(f"two live targets claim the path '{path}'")
            claimed.add(path)
        check_relative("ledger", target["ledger"])
        if "lock" in target:
            check_relative("lock", target["lock"])
            if target["codec"] == "dir":
                raise ValueError(f"lock is for document targets only: {target['path']}")
        if target["ledger"] in ledgers:
            raise ValueError(f"two targets share the ledger '{target['ledger']}'")
        ledgers.add(target["ledger"])
        if target["codec"] == "dir":
            for address in target["units"]:
                if not address or "/" in address or address.startswith("."):
                    raise ValueError(
                        f"unit address must be one visible path segment: "
                        f"'{address}' in {target['path']}"
                    )
    return plan


# ── Driver ──────────────────────────────────────────────────────────


def run(plan: Mapping[str, Any], root: Path, state: Path, phase: str) -> None:
    targets = plan["targets"]
    # `live` keys on the DECLARATION, not on what a producer resolves to: a
    # merge producer declared with zero servers still claims its path. It is
    # read from EVERY target, including the ones this phase will not touch --
    # a co-owner's claim does not depend on which phase is running.
    live = {str(PurePosixPath(target["path"])) for target in targets if target["units"]}

    # A document's retraction and assertion are ONE read-modify-write.
    # Splitting them across two processes would leave the deletions applied if
    # the second died, so the prune phase drops document targets here -- before
    # resolution, so a phase that cannot use a renderer's output never runs it.
    considered = [
        target for target in targets if phase != "prune" or target["codec"] == "dir"
    ]
    # The prune phase resolves NO content. A retraction needs the declared
    # ADDRESSES, never their bytes: it removes what the ledger records and the
    # declaration dropped. Running a renderer here would also read a SECRET in
    # the entry that runs before checkLinkTargets -- earlier than any secret
    # provider's own activation entry -- so kiro's mcp.json would abort the
    # first switch on a credential url that does not exist yet.
    resolved = [
        [(address, None) for address in sorted(target["units"])]
        if phase == "prune"
        else units_of(target, plan["bash"])
        for target in considered
    ]

    # Virgin and empty is a strict no-op: no lock, no state directory, no
    # target directory, nothing. Resolution above has already run, so a
    # renderer that fails cannot be masked by this early return.
    if not any(
        units or ledger_path(state, target).exists()
        for target, units in zip(considered, resolved)
    ):
        return

    # Parse every document once BEFORE the lock, and throw away the result.
    # A malformed native edit already fails closed under the lock, but the
    # lock file's own directory is the first thing this run would create, so
    # without this pre-flight a document that cannot be parsed leaves a state
    # tree behind. "A malformed config changes neither the file nor ownership"
    # is asserted as the absence of the whole state directory
    # (packages/chatgpt-codex/checks/module-eval.nix, malformed-TOML case), and
    # that is the honest property: a run that refused to do anything should not
    # be distinguishable from one that never started.
    #
    # Documents only. DocContainer's constructor reads, while DirContainer's
    # creates the target directory and sweeps reserved temporaries, and those
    # side effects belong under the lock. The skip below mirrors the locked
    # phase exactly, so a target the locked phase would not open is not opened
    # here either.
    #
    # A document whose native writer takes a lock is read under that lock,
    # here and below: pi rewrites trust.json in place with writeFileSync, so an
    # unlocked read can parse half a file and an unlocked write can lose the
    # decision a prompt was saving. The native lock is taken AFTER this run's
    # own flock below, so a wait on a concurrent reconcile never ages it
    # toward stale while this run holds it.
    native = [root / target["lock"] for target in considered if "lock" in target]
    with foreign_locks(native):
        for target, units in zip(considered, resolved):
            ledger = ledger_path(state, target)
            if target["codec"] == "dir" or (
                not units and not ledger_format(target["codec"])[0](ledger)
            ):
                continue
            open_container(root, target, ledger)

    lock = state.joinpath(*LOCK)
    lock.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with lock.open("a") as handle, contextlib.ExitStack() as native_held:
        # flock releases on process death, so a killed activation cannot
        # strand a lock that turns every later run into manual recovery.
        fcntl.flock(handle, fcntl.LOCK_EX)
        native_held.enter_context(foreign_locks(native))

        opened = []
        for target, units in zip(considered, resolved):
            ledger = ledger_path(state, target)
            previous = ledger_format(target["codec"])[0](ledger)
            if not units and not previous:
                # An empty declaration with an empty or absent ledger owns
                # nothing: drop the ledger and touch nothing else. Opening the
                # container here would parse a document that may be externally
                # managed and even malformed, failing a run with no work to do.
                # The prune phase never rewrites a ledger, so it leaves even
                # this to the write phase.
                if phase != "prune":
                    ledger.unlink(missing_ok=True)
                continue
            opened.append((target, units, previous or {}, ledger, open_container(root, target, ledger)))

        conflicts = 0

        def report(conflict: Conflict) -> None:
            nonlocal conflicts
            conflicts += 1
            print(f"ERROR: own: {conflict}", file=sys.stderr)

        # Every retraction, across every target, before any assertion.
        for target, units, previous, ledger, box in opened:
            declared = {address for address, _ in units}
            for address in box.stale_order(set(previous) - declared):
                # THE RETRACTION RULE: a stale unit is removed through the
                # container that recorded it, EXCEPT a whole-file unit whose
                # path is a live target in this plan with a non-empty `units`
                # declaration -- that one is forgotten, not removed.
                if box.released_path(address) in live:
                    continue
                try:
                    box.remove(address, previous[address])
                except Conflict as conflict:
                    report(conflict)

        if phase != "prune":
            # A target that declares nothing is already finished, and it must
            # be FLUSHED before any assertion runs. A document's retraction
            # only reaches the disk at commit, and a co-owner in this same
            # plan may be about to take that very path over: the 2->3 handover
            # is what the old code hand-spliced as reconcile-then-materialize
            # ordering in one mode and the reverse in the other.
            for target, units, previous, ledger, box in opened:
                if not units:
                    box.commit(retiring=True)
                    write_ledger(target["codec"], ledger, {})

            # Every assertion.
            for target, units, previous, ledger, box in opened:
                if not units:
                    continue
                written: dict[Any, Any] = {}
                for address, unit in units:
                    try:
                        written[address] = box.assert_unit(
                            address, unit, previous.get(address)
                        )
                    except Conflict as conflict:
                        report(conflict)
                box.commit()
                write_ledger(target["codec"], ledger, written)

        if conflicts:
            # Deferred, not raised at the site: one unguarded target must not
            # strand the others, and the ledger above must already record what
            # did land before the run fails.
            print(
                "ERROR: own: unresolved target conflicts (see messages above)",
                file=sys.stderr,
            )
            raise SystemExit(1)


def leaf_present(document: Any, address: tuple[str, ...]) -> bool:
    current = document
    for segment in address:
        if not isinstance(current, Mapping) or segment not in current:
            return False
        current = current[segment]
    return True


def verify(plan: Mapping[str, Any], root: Path, state: Path) -> None:
    """Assert what a completed run claims to have published.

    A failed writer only warns at shell entry; this is what makes `devenv
    test` and CI fail. It resolves NO content: a renderer can touch a secret,
    and re-running one is not something a test may do.
    """
    failures: list[str] = []
    for target in plan["targets"]:
        if target["codec"] == "dir":
            for address in sorted(target["units"]):
                unit = root / target["path"] / address
                if not unit.is_file() or unit.is_symlink():
                    failures.append(
                        f"{target['path']}/{address} is not materialized as a real file"
                    )
            continue
        previous = ledger_format(target["codec"])[0](ledger_path(state, target))
        if not previous:
            continue
        document = open_container(root, target, ledger_path(state, target)).document
        for address in sorted(previous):
            if not leaf_present(document, address):
                failures.append(
                    f"{target['path']} is missing the owned leaf {'.'.join(address)}"
                )
    for failure in failures:
        print(f"FAIL: own: {failure}", file=sys.stderr)
    if failures:
        raise SystemExit(1)


def main() -> None:
    args = parse_args()
    try:
        plan = load_plan(args.plan)
        root, state = require_env("NAT_OWN_ROOT"), require_env("NAT_OWN_STATE")
        if args.verify:
            verify(plan, root, state)
        else:
            run(plan, root, state, args.phase)
    except (OSError, ValueError) as error:
        # Loud but concise. A parser traceback obscures the actionable path
        # and invites users to read activation output as implementation
        # noise; a programming error still escapes with its trace.
        print(f"own: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()

"""Reconcile owned files against a normalized files2 plan."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

codec_spec = importlib.util.spec_from_file_location("files2_codecs", Path(__file__).with_name("files2_codecs.py"))
codecs = importlib.util.module_from_spec(codec_spec)
codec_spec.loader.exec_module(codecs)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def valid_path(path):
    return isinstance(path, str) and bool(path) and not path.startswith("/") and all(
        part not in ("", ".", "..") for part in path.split("/")
    )


def image(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"type": "absent"}
    if stat.S_ISREG(info.st_mode):
        return {"type": "file", "digest": digest(path.read_bytes()), "mode": stat.S_IMODE(info.st_mode)}
    if stat.S_ISLNK(info.st_mode):
        return {"type": "symlink", "target": os.readlink(path)}
    raise ValueError(f"special file refused: {path}")


def atomic_json(path, value):
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    atomic_bytes(path, data, 0o600)


def atomic_bytes(path, data, mode, guard=None):
    fd, temporary = tempfile.mkstemp(prefix=".files2-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        if guard is not None and not guard():
            return False
        os.replace(temporary, path)
        return True
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parent(root, relative, create=False):
    current = root
    for segment in relative.split("/")[:-1]:
        current = current / segment
        try:
            info = current.lstat()
        except FileNotFoundError:
            if not create:
                continue
            current.mkdir()
            info = current.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"symlinked or non-directory parent refused: {current}")
    return root / relative


def validate_state(state, version):
    if not isinstance(state, dict) or type(state.get("version")) is not int or state["version"] != version or set(state) != {"version", "files"}:
        raise ValueError("invalid files2 state schema")
    if not isinstance(state.get("files"), dict):
        raise ValueError("invalid files2 state files")
    for path, item in state["files"].items():
        if not valid_path(path):
            raise ValueError(f"invalid state path: {path}")
        if not isinstance(item, dict) or set(item) != {"created", "digest", "format", "keys", "method", "mode"}:
            raise ValueError(f"invalid state entry: {path}")
        if (type(item["created"]) is not bool or not isinstance(item["digest"], str)
                or re.fullmatch(r"[0-9a-f]{64}", item["digest"]) is None
                or item["format"] not in ("json", "markdown", "raw", "toml", "yaml")
                or item["method"] not in ("ro", "rw")
                or type(item["mode"]) is not int or not 0 <= item["mode"] <= 0o7777
                or not isinstance(item["keys"], dict)):
            raise ValueError(f"invalid state entry: {path}")
        if item["method"] == "rw" and item["format"] not in codecs.FORMATS:
            raise ValueError(f"invalid rw state: {path}")
        if item["method"] == "ro" and item["keys"]:
            raise ValueError(f"invalid ro state keys: {path}")
        for address, value in item["keys"].items():
            if (not isinstance(address, str) or not address.startswith("/")
                    or re.search(r"~(?![01])", address) or pointer(pointer_parts(address)) != address
                    or not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None):
                raise ValueError(f"invalid state key: {path}")


def migrate_v0(state):
    return {**state, "version": 1}


MIGRATIONS = {0: migrate_v0}
CURRENT_VERSION = 1


def load_state(state_path):
    if not state_path.exists():
        return {"files": {}, "version": CURRENT_VERSION}
    state = json.loads(state_path.read_text())
    version = state.get("version") if isinstance(state, dict) else None
    if type(version) is not int or version < 0 or version > CURRENT_VERSION:
        raise ValueError(f"unsupported files2 state version: {state_path}")
    validate_state(state, version)
    migrated = version < CURRENT_VERSION
    while version < CURRENT_VERSION:
        migration = MIGRATIONS.get(version)
        if migration is None:
            raise ValueError(f"missing files2 state migration from version {version}: {state_path}")
        state = migration(state)
        version += 1
        validate_state(state, version)
    if migrated:
        save(state_path, state)
    return state


def entry(data, mode):
    return {
        "method": "ro",
        "format": data["format"],
        "digest": digest(data["bytes"]),
        "mode": mode,
        "created": data["created"],
        "keys": {},
    }


def desired_data(item):
    content = item["content"]
    if "text" in content:
        payload = content["text"].encode()
        source_mode = 0o444
    elif "source" in content:
        source = Path(content["source"])
        if not source.is_file():
            raise ValueError(f"source must be a file: {source}")
        payload = source.read_bytes()
        source_mode = stat.S_IMODE(source.stat().st_mode)
    elif "value" in content and item["format"] in codecs.FORMATS:
        payload = Path(content["rendered"]).read_bytes()
        source_mode = 0o444
    elif "run" in content:
        script = "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + content["run"]
        payload = subprocess.run([os.environ["FILES2_BASH"], "-c", script], check=True, stdout=subprocess.PIPE).stdout
        source_mode = 0o444
    else:
        raise ValueError(f"unsupported ro content at {item['path']}")
    if item["mode"] is not None:
        mode = int(item["mode"], 8)
    elif item["executable"] is True:
        mode = 0o555
    elif item["executable"] is False:
        mode = 0o444
    else:
        mode = 0o444 | (source_mode & 0o111)
    return payload, mode


def backup_path(state_path, relative, before):
    identity = json.dumps([relative, before["digest"], before["mode"]], separators=(",", ":")).encode()
    return state_path.parent / f"{state_path.stem[:32]}-{digest(identity)[:32]}.bak"


def backup_old(destination, backup, before):
    if backup is None:
        return
    if backup.exists():
        if image(backup) != before:
            raise ValueError(f"reserved backup differs: {backup}")
        return
    if image(destination) != before:
        raise ValueError(f"destination changed before backup: {destination}")
    atomic_bytes(backup, destination.read_bytes(), before["mode"])


def save(state_path, state):
    atomic_json(state_path, state)


def finish(state_path, state, relative, next_entry):
    if next_entry is None:
        state["files"].pop(relative, None)
    else:
        state["files"][relative] = next_entry
    save(state_path, state)


def installed_image(previous):
    if previous is None:
        return {"type": "absent"}
    return {"type": "file", "digest": previous["digest"], "mode": previous["mode"]}


def mutate(root, state_path, state, relative, after, next_entry=None, payload=None, observed=None):
    destination = parent(root, relative, create=after["type"] == "file")
    current = image(destination)
    if observed is not None and current != observed:
        raise ValueError(f"concurrent destination change: {relative}")
    installed = installed_image(state["files"].get(relative))
    if current["type"] not in ("file", "absent") and current != installed:
        raise ValueError(f"owned destination changed type: {relative}")
    if after["type"] == current["type"] == "file" and after["digest"] == current["digest"] and after != current:
        # Only permission bits differ, so a backup would preserve nothing:
        # git rewrites a committed copy at 0644 with the same bytes.
        os.chmod(destination, after["mode"])
        current = after
    if current == after:
        finish(state_path, state, relative, next_entry)
        return True
    backup = backup_path(state_path, relative, current) if current["type"] == "file" and current != installed else None
    if after["type"] == "file":
        if payload is None or digest(payload) != after["digest"]:
            raise ValueError(f"replacement payload unavailable or changed: {relative}")
        destination = parent(root, relative, create=True)
        backup_old(destination, backup, current)
        def unchanged():
            return image(destination) == current
        if not atomic_bytes(destination, payload, after["mode"], guard=unchanged):
            raise ValueError(f"concurrent destination change: {relative}")
    elif after["type"] == "absent":
        backup_old(destination, backup, current)
        if image(destination) != current:
            raise ValueError(f"concurrent destination change: {relative}")
        if current != {"type": "absent"}:
            destination.unlink()
    else:
        raise ValueError(f"unsupported replacement image: {relative}")
    finish(state_path, state, relative, next_entry)
    return True


def retire(root, state_path, state, relative):
    previous = state["files"][relative]
    destination = parent(root, relative)
    if previous["method"] == "ro":
        current = image(destination)
        if current["type"] not in ("file", "absent"):
            raise ValueError(f"owned copy changed type: {relative}")
    else:
        retire_rw(root, state_path, state, relative, None)
        return
    mutate(root, state_path, state, relative, {"type": "absent"})


def pointer(address):
    return "/" + "/".join(part.replace("~", "~0").replace("/", "~1") for part in address)


def pointer_parts(address):
    return tuple(part.replace("~1", "/").replace("~0", "~") for part in address[1:].split("/"))


def key_digest(value):
    plain = codecs.plain(value)
    return digest(json.dumps([type(plain).__name__, plain], sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                             default=lambda item: {"type": type(item).__name__, "value": str(item)}).encode())


def lookup(document, address):
    node = document
    for part in address:
        if not hasattr(node, "items") or part not in node:
            return False, None
        node = node[part]
    return True, node


def remove_key(document, address):
    parents = []
    node = document
    for part in address[:-1]:
        if not hasattr(node, "items") or part not in node:
            return
        parents.append((node, part))
        node = node[part]
    if hasattr(node, "items"):
        node.pop(address[-1], None)
    for parent_node, part in reversed(parents):
        if parent_node[part]:
            break
        del parent_node[part]


def set_key(document, address, value, relative):
    node = document
    for part in address[:-1]:
        if part not in node:
            node[part] = {}
        if not hasattr(node[part], "items"):
            raise ValueError(f"map-to-scalar conflict: {relative} {pointer(address)}")
        node = node[part]
    old = node.get(address[-1])
    if hasattr(old, "items"):
        raise ValueError(f"map-to-scalar conflict: {relative} {pointer(address)}")
    node[address[-1]] = value


def read_document(destination, format_name, relative):
    current = image(destination)
    if current["type"] == "absent":
        return {}, "", False, current
    if current["type"] != "file":
        raise ValueError(f"non-regular destination refused: {relative}")
    data = destination.read_bytes()
    if digest(data) != current["digest"]:
        raise ValueError(f"concurrent destination change: {relative}")
    try:
        document, prefix, comments = codecs.parse(format_name, data)
    except Exception as error:
        raise ValueError(f"malformed {format_name} document: {relative}: {error}") from error
    return document, prefix, comments, current


def retire_rw(root, state_path, state, relative, replacement):
    previous = state["files"][relative]
    destination = parent(root, relative)
    document, prefix, comments, current = read_document(destination, previous["format"], relative)
    if current["type"] == "absent":
        state["files"].pop(relative)
        save(state_path, state)
        return
    changed = False
    for address in sorted(previous["keys"], key=lambda key: (-key.count("/"), key)):
        found, value = lookup(document, pointer_parts(address))
        if found:
            if hasattr(value, "items"):
                if value:
                    raise ValueError(f"native descendants prevent retirement: {relative} {address}")
                continue
            changed = True
            remove_key(document, pointer_parts(address))
    remaining = bool(document)
    if replacement and (remaining or comments or not previous["created"]):
        raise ValueError(f"native keys or preserved comments prevent takeover: {relative}")
    delete = previous["created"] and not remaining and not comments
    after_payload = codecs.serialize(previous["format"], document, prefix) if changed else destination.read_bytes()
    after = {"type": "absent"} if delete else {"type": "file", "digest": digest(after_payload), "mode": current["mode"]}
    mutate(root, state_path, state, relative, after, payload=None if delete else after_payload, observed=current)


def rw_candidate(root, state, relative, item):
    previous = state["files"].get(relative)
    if previous and previous["method"] not in ("ro", "rw"):
        raise ValueError(f"prior method requires prune: {relative}")
    desired_bytes, declared_mode = desired_data(item)
    try:
        declared, _, _ = codecs.parse(item["format"], desired_bytes)
    except Exception as error:
        raise ValueError(f"malformed {item['format']} declaration: {relative}: {error}") from error
    wanted = {pointer(address): value for address, value in codecs.leaves(declared)}
    destination = parent(root, relative, create=True)
    old_format = previous["format"] if previous and previous["format"] in codecs.FORMATS else item["format"]
    document, prefix, comments, current = read_document(destination, old_format, relative)
    old_keys = previous["keys"] if previous and previous["method"] == "rw" else {}
    changed = False
    for address in sorted(old_keys.keys() - wanted.keys(), key=lambda key: (-key.count("/"), key)):
        found, value = lookup(document, pointer_parts(address))
        if found:
            if hasattr(value, "items"):
                if value:
                    raise ValueError(f"native descendants prevent retirement: {relative} {address}")
                continue
            changed = True
            remove_key(document, pointer_parts(address))
    for address, value in wanted.items():
        found, existing = lookup(document, pointer_parts(address))
        if not found or key_digest(existing) != key_digest(value):
            set_key(document, pointer_parts(address), value, relative)
            changed = True
    if old_format != item["format"] and comments:
        raise ValueError(f"comment-preserving format switch refused: {relative}")
    if old_format != item["format"]:
        document, prefix, comments = codecs.plain(document), "", False
    payload = (destination.read_bytes() if current["type"] == "file" and not changed and old_format == item["format"]
               else codecs.serialize(item["format"], document, prefix))
    if item["mode"] is not None:
        mode = int(item["mode"], 8)
    elif item["executable"] is not None:
        mode = 0o700 if item["executable"] else 0o600
    elif previous and previous["method"] == "ro":
        mode = 0o600 | (current.get("mode", previous["mode"]) & 0o111)
    else:
        mode = current.get("mode", 0o600 | (declared_mode & 0o111))
    next_entry = {"method": "rw", "format": item["format"], "digest": digest(payload), "mode": mode,
                  "created": previous["created"] if previous else current["type"] == "absent",
                  "keys": {address: key_digest(value) for address, value in wanted.items()}}
    return payload, next_entry, current


def reconcile_rw(root, state_path, state, relative, item):
    payload, next_entry, current = rw_candidate(root, state, relative, item)
    after = {"type": "file", "digest": next_entry["digest"], "mode": next_entry["mode"]}
    mutate(root, state_path, state, relative, after, next_entry, payload, observed=current)


def reconcile_ro(root, state_path, state, relative, item):
    previous = state["files"].get(relative)
    if previous and previous["method"] != "ro":
        raise ValueError(f"prior method requires prune: {relative}")
    payload, mode = desired_data(item)
    destination = parent(root, relative, create=True)
    current = image(destination)
    if current["type"] not in ("file", "absent"):
        raise ValueError(f"non-regular destination refused: {relative}")
    data = {**item, "bytes": payload, "created": previous["created"] if previous else current["type"] == "absent"}
    next_entry = entry(data, mode)
    after = {"type": "file", "digest": next_entry["digest"], "mode": mode}
    mutate(root, state_path, state, relative, after, next_entry, payload, observed=current)


def read_ledger(path, codec):
    """Units of a legacy ownership ledger, by its original reader's rules; None when absent."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"legacy ledger must be a regular file: {path}")
    try:
        text = path.read_bytes().decode()
        if codec == "dir":
            units = {}
            for line in text.splitlines():
                name, _, witness = line.partition("\t")
                if name and "/" not in name and not name.startswith("."):
                    units[name] = witness
            return units
        ledger = json.loads(text)
    except ValueError as error:
        raise ValueError(f"malformed legacy ledger: {path}: {error}") from error
    addresses = ledger.get("managed_paths") if isinstance(ledger, dict) and ledger.get("version") == 1 else None
    if (not isinstance(addresses, list)
            or not all(isinstance(address, list) and address and all(isinstance(part, str) for part in address)
                       for address in addresses)
            or len({tuple(address) for address in addresses}) != len(addresses)):
        raise ValueError(f"malformed legacy ledger: {path}")
    return [tuple(address) for address in addresses]


def legacy_entry(root, ledger, relative, record):
    """The state entry for one old copy still on disk, or None to skip it.

    `record` is a `dir` unit's witness or a `json` ledger's addresses.
    """
    if not valid_path(relative):
        raise ValueError(f"invalid legacy ledger path: {ledger['ledger']}: {relative}")
    destination = parent(root, relative)
    current = image(destination)
    if current["type"] == "absent":
        return None
    if ledger["codec"] == "dir":
        # An old native link rather than an owned copy.
        if current["type"] != "file":
            return None
        recorded = record if re.fullmatch(r"[0-9a-f]{64}", record) else current["digest"]
        return {"created": True, "digest": recorded, "format": "raw", "keys": {}, "method": "ro",
                "mode": current["mode"]}
    document, _, _, current = read_document(destination, "json", relative)
    keys = {}
    for address in sorted(record):
        found, value = lookup(document, address)
        if found:
            keys[pointer(address)] = key_digest(value)
    return {"created": False, "digest": current["digest"], "format": "json", "keys": keys, "method": "rw",
            "mode": current["mode"]}


def import_legacy(root, state_path, state, legacy, legacy_state):
    """Adopt each listed old ledger into state once, then delete the ledger."""
    for ledger in sorted(legacy, key=lambda item: item["ledger"]):
        if not valid_path(ledger["ledger"]):
            raise ValueError(f"invalid legacy ledger: {ledger['ledger']}")
        location = parent(legacy_state, ledger["ledger"])
        units = read_ledger(location, ledger["codec"])
        if units is None:
            continue
        if ledger["codec"] == "json":
            targets = [(ledger["path"], units)]
        else:
            targets = [(name if ledger["path"] == "." else f"{ledger['path']}/{name}", witness)
                       for name, witness in sorted(units.items())]
        files = dict(state["files"])
        for relative, record in targets:
            if relative not in files:
                found = legacy_entry(root, ledger, relative, record)
                if found is not None:
                    files[relative] = found
        validate_state({**state, "files": files}, CURRENT_VERSION)
        state["files"] = files
        save(state_path, state)
        location.unlink()


def reconcile(plan, root, state_path, phase, legacy=(), legacy_state=None):
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"root must be a real directory: {root}")
    seen = set()
    for item in plan:
        relative = item["path"]
        if not valid_path(relative) or relative in seen or item["method"] not in ("ro", "rw", "symlink"):
            raise ValueError(f"invalid plan entry: {relative}")
        seen.add(relative)
    state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_path.parent.chmod(0o700)
    if state_path.is_symlink():
        raise ValueError(f"state symlink refused: {state_path}")
    lock = state_path.with_suffix(state_path.suffix + ".lock")
    if lock.is_symlink():
        raise ValueError(f"state lock symlink refused: {lock}")
    with lock.open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        state = load_state(state_path)
        import_legacy(root, state_path, state, legacy, legacy_state)
        desired = {item["path"]: item for item in plan}
        if phase == "prune":
            for relative in sorted(list(state["files"])):
                old = state["files"][relative]
                new = desired.get(relative)
                if old["method"] == "ro" and (new is None or new["method"] == "symlink"):
                    retire(root, state_path, state, relative)
                elif old["method"] == "rw" and (new is None or new["method"] != "rw"):
                    retire_rw(root, state_path, state, relative, new)
        else:
            for relative in sorted(list(state["files"])):
                if relative not in desired and state["files"][relative]["method"] in ("ro", "rw"):
                    retire(root, state_path, state, relative)
        for relative in sorted(desired):
            parent(root, relative)
        if phase == "apply":
            for relative, item in sorted(desired.items()):
                if item["method"] == "rw":
                    reconcile_rw(root, state_path, state, relative, item)
                    continue
                if item["method"] == "ro":
                    reconcile_ro(root, state_path, state, relative, item)
        # No state file means nothing is owned; prune of an empty map skips on it.
        if state["files"]:
            save(state_path, state)
        else:
            state_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--phase", choices=("prune", "apply"), required=True)
    parser.add_argument("--legacy-plan", default="[]")
    parser.add_argument("--legacy-state", type=Path)
    args = parser.parse_args()
    reconcile(json.loads(args.plan.read_text()), args.root, args.state, args.phase,
              json.loads(args.legacy_plan), args.legacy_state)


if __name__ == "__main__":
    main()

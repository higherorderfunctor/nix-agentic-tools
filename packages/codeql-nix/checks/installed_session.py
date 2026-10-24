"""Immutable reuse for compatible installed CodeQL acceptance databases."""

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import uuid


def tree_digest(path: Path) -> str:
    """Hash filesystem kind, path, permissions, and payload without following links."""
    digest = hashlib.sha256()
    entries = [path, *path.rglob("*")]
    for entry in sorted(entries, key=lambda item: item.relative_to(path).as_posix()):
        metadata = entry.lstat()
        kind = ("symlink" if stat.S_ISLNK(metadata.st_mode) else
                "file" if stat.S_ISREG(metadata.st_mode) else
                "directory" if stat.S_ISDIR(metadata.st_mode) else "other")
        framing = [entry.relative_to(path).as_posix(), kind, stat.S_IFMT(metadata.st_mode), metadata.st_mode & 0o777]
        digest.update(json.dumps(framing, separators=(",", ":")).encode())
        if kind == "symlink":
            payload = os.readlink(entry).encode()
        elif kind == "file":
            payload = entry.read_bytes()
        else:
            payload = b""
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def _canonical(value) -> bytes:
    def prepare(item):
        if isinstance(item, bytes):
            return {"bytesBase64": base64.b64encode(item).decode("ascii")}
        if isinstance(item, dict):
            return {key: prepare(child) for key, child in item.items()}
        if isinstance(item, list):
            return [prepare(child) for child in item]
        return item
    return json.dumps(prepare(value), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def variant_key(source: Path, *, inputs, manifest, options, identities, failure="success") -> str:
    """Return the complete immutable identity of one installed database."""
    payload = {
        "failure": failure,
        "identities": identities,
        "inputs": inputs,
        "manifest": manifest,
        "options": options,
        "source": tree_digest(Path(source)),
    }
    return hashlib.sha256(_canonical(payload)).hexdigest()


class Session:
    """Build, validate and publish databases keyed by :func:`variant_key`."""

    def __init__(self, directory: Path):
        self.directory = Path(directory)

    def database(self, key, build, validate) -> Path:
        self.directory.mkdir(parents=True, exist_ok=True)
        lock = self.directory / ".lock"
        with lock.open("a+") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            final = self.directory / key
            if final.exists():
                validate(final)
                return final
            staging = self.directory / f".staging-{key}-{uuid.uuid4().hex}"
            staging.mkdir()
            log = os.environ.get("CODEQL_NIX_TEST_SESSION_MISS_LOG")
            if log:
                with Path(log).open("a") as stream:
                    stream.write(key + "\n")
            try:
                build(staging)
                if not (staging / "ready").is_file():
                    raise ValueError("database was not finalized")
                validate(staging)
                os.replace(staging, final)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
            return final

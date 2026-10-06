"""Pinned Codex binary, source and a scratch models_cache.json for the codex-side scripts."""
import os
import pathlib
import subprocess
import sys

S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S.parent / "common"))
import pin  # noqa: E402


def binary():
    return os.environ.get("CODEX_BIN") or str(pin.package("chatgpt-codex") / "bin" / "codex")


def source():
    return pin.source("chatgpt-codex")


def models_cache(work):
    """Path of a models_cache.json built from the pinned source's bundled catalog (mkcache.py)."""
    path = pathlib.Path(work) / "models_cache.json"
    if not path.exists():
        subprocess.run([sys.executable, str(S / "mkcache.py"), str(source()), str(path)], check=True)
    return path


def workdir(name):
    return pin.workdir(name)


def repo_root():
    return pin.repo_root()

"""Prepare desired devenv links before devenv's native files task."""

import argparse
import json
import os
import stat
from pathlib import Path


def checked_destination(root, relative):
    current = root
    for segment in relative.split("/")[:-1]:
        current = current / segment
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(mode):
            raise ValueError(f"symlinked or non-directory parent refused: {current}")
    return root / relative


def prepare(root, targets):
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"root must be a real directory: {root}")
    for relative, desired in sorted(targets.items()):
        destination = checked_destination(root, relative)
        try:
            mode = destination.lstat().st_mode
        except FileNotFoundError:
            continue
        if not stat.S_ISLNK(mode):
            raise ValueError(f"native link destination refused: {relative}")
        current = os.readlink(destination)
        if current == desired:
            continue
        if not current.startswith("/nix/store/"):
            raise ValueError(f"non-store link refused: {relative}")
        destination.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--targets", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.root, json.loads(args.targets.read_text()))


if __name__ == "__main__":
    main()

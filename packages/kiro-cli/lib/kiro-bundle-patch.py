"""Apply named exact-byte replacements to Kiro's extracted KAS bundle.

Each selected source must occur exactly once; any drift refuses the entire
build before writing output. No JavaScript parsing or steering decoding is
needed: the sources below are the pinned bundle's literal bytes.
"""

import argparse
from pathlib import Path
import sys

WORKTREE_PARAGRAPH = rb"""When a task should run in a worktree, say so in the brief and name the base branch (the branch checked out in the user\'s repo, not necessarily the default). The workflow\'s first step creates `.worktrees/<name>` on a branch named from the task, its last step rebases onto the base and fast-forwards it from the user\'s checkout (`git -C <repo> merge --ff-only <branch>`, since git will not move a branch checked out in another worktree), and you remove the worktree and branch after the run. Do not create the worktree yourself.\n\n"""
FILE_CHECK_PARAGRAPH = rb"""5. **Every path is absolute**, in prompts and in `fileCheck.path`: step agents run in the parent session\'s workspace, not in a worktree, and a `fileCheck.path` that never resolves spins the loop to `maxIterations`. Tell worktree steps to use `git -C <absolute worktree>`."""
# Our authored replacement, spelled out so the text Kiro receives is readable
# here. The stop-condition file is the exception to absolute paths: the
# step writes it and `fileCheck.path` checks it at one workspace-relative path.
RELATIVE_FILE_CHECK_PARAGRAPH = (
    rb"""5. **Every path in a step prompt is absolute, except the stop-condition file.** """
    rb"""Step agents run in the parent session\'s workspace, not in a worktree, so write every other file a step reads, writes, or commits as a literal absolute path, and tell worktree steps to use `git -C <absolute worktree>`. """
    rb"""The file a `stopCondition` or `completion` checks is written by the step and checked by `fileCheck.path` at the same relative path: a plain path relative to the workflow workspace root (e.g. `.agents/tasks/review.json`), without templates or an absolute worktree prefix. """
    rb"""Step agents\' cwd is that root, so the writing step and the check agree. """
    rb"""A `fileCheck.path` that never resolves spins the loop to `maxIterations`."""
)
# Fixed-text tweaks, keyed by their `ai.kiro.cli.tweaks` option name.
FIXED = {
    "relativeFileCheckPaths": (FILE_CHECK_PARAGRAPH, RELATIVE_FILE_CHECK_PARAGRAPH),
    "stripVendorWorktreeSteering": (WORKTREE_PARAGRAPH, b""),
}


def replacements(names):
    return [(name, *FIXED[name]) for name in names]


def patch(data, items):
    """Return patched bytes, or no output if any selected source drifted."""
    errors = []
    result = data
    for name, source, replacement in items:
        count = data.count(source)
        if count != 1:
            errors.append(f"{name}: expected exact source text once, found {count}; bundle drift")
        else:
            result = result.replace(source, replacement, 1)
    return (None if errors else result), errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--replace", action="append", choices=FIXED, default=[])
    args = parser.parse_args()
    if not args.check and args.destination is None:
        parser.error("destination is required unless --check is set")
    try:
        items = replacements(list(FIXED) if args.check else args.replace)
        result, errors = patch(args.source.read_bytes(), items)
        for error in errors:
            print(f"FAIL: kiro-bundle-patch: {error}", file=sys.stderr)
        if errors:
            return 1
        if args.check:
            print("PASS: " + ", ".join(name for name, _, _ in items) + " exact sources each occur once")
        else:
            args.destination.write_bytes(result)
    except OSError as exc:
        print(f"FAIL: kiro-bundle-patch: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

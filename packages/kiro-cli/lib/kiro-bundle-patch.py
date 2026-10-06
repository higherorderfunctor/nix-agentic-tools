"""Apply named exact-byte replacements to Kiro's extracted KAS bundle.

Each selected source must occur exactly once. CI fails on every drifted
replacement; launch warns and skips only that replacement, using stock when
none apply. No JavaScript parsing or steering decoding is
needed: the sources below are the pinned bundle's literal bytes.
"""

import argparse
from pathlib import Path
import sys

IDENTITY_SENTENCE = b"You are Kiro CLI, an agentic AI software engineer that runs in the command line."
WORKTREE_PARAGRAPH = b"When a task should run in a worktree, the **workflow owns the worktree setup** \\u2014 do NOT create the worktree yourself. Say in the `workflowPrompt` brief that a worktree is needed and let the generated workflow\\'s first step create it (`git worktree add .worktrees/<name> -b <branch> mainline`) and run all later steps targeting that worktree. Derive a descriptive `<name>`/`<branch>` from the task. The workflow\\'s final step rebases the branch onto `mainline` and fast-forwards `mainline`; you remove the worktree and branch after the run completes (an in-worktree step can\\'t safely delete the directory it is running in).\\n\\n"
FILE_CHECK_PARAGRAPH = b'13. **Every path in a prompt or stop condition is absolute.** Step agents\' cwd is the parent session\'s workspace, not a worktree or subdirectory, so a relative path in a prompt silently resolves to the wrong place. Interpolate an input (e.g. \\`{{worktree_path}}/src/file.ts\\`) for every file a step reads, writes, or commits, and tell worktree steps to use \\`git -C <absolute worktree>\\` rather than describing the worktree as their "working directory". The same applies to \\`fileCheck.path\\` in a \\`stopCondition\\` or \\`completion\\`: relative paths resolve against the workflow\'s workspace root, and a path that never resolves evaluates false forever \\u2014 the loop then spins to \\`maxIterations\\` instead of stopping.'
# Our authored replacement, spelled out so the text Kiro receives is readable
# here. The stop-condition file is the exception to absolute interpolation: the
# step writes it and `fileCheck.path` checks it at one workspace-relative path.
RELATIVE_FILE_CHECK_PARAGRAPH = (
    rb"""13. **Every path in a step prompt is absolute, except the stop-condition file.** """
    rb"""Step agents' cwd is the parent session's workspace, not a worktree or subdirectory, so a relative path in a prompt silently resolves to the wrong place. """
    rb"""Interpolate an input (e.g. \`{{worktree_path}}/src/file.ts\`) for every other file a step reads, writes, or commits, and tell worktree steps to use \`git -C <absolute worktree>\` rather than describing the worktree as their "working directory". """
    rb"""The file a \`stopCondition\` or \`completion\` checks is written by the step and checked by \`fileCheck.path\` at the same relative path: a plain path relative to the workflow workspace root (e.g. \`.agents/tasks/review.json\`), without templates or an absolute worktree prefix. """
    rb"""Step agents' cwd is that root, so the writing step and the check agree. """
    rb"""A path that never resolves evaluates false forever \u2014 the loop then spins to \`maxIterations\` instead of stopping."""
)
# Fixed-text tweaks, keyed by their `ai.kiro.tweaks` option name.
FIXED = {
    "relativeFileCheckPaths": (FILE_CHECK_PARAGRAPH, RELATIVE_FILE_CHECK_PARAGRAPH),
    "stripVendorWorktreeSteering": (WORKTREE_PARAGRAPH, b""),
}


def replacements(identity=None, names=()):
    items = []
    if identity is not None:
        identity = identity.strip()
        if not identity or identity[-1:] not in (b".", b"!", b"?"):
            raise ValueError("identity: replacement must end with sentence punctuation (. ! ?)")
        if b"`" in identity or b"${" in identity:
            raise ValueError("identity: replacement may not contain a backtick or `${`")
        items.append(("identity", IDENTITY_SENTENCE, identity))
    return items + [(name, *FIXED[name]) for name in names]


def patch(data, items):
    """Return the independently patched bytes (or None) and named drift errors."""
    errors = []
    result = data
    applied = False
    for name, source, replacement in items:
        count = data.count(source)
        if count != 1:
            errors.append(f"{name}: expected exact source text once, found {count}; bundle drift")
        else:
            result = result.replace(source, replacement, 1)
            applied = True
    return (result if applied else None), errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--identity-file", type=Path)
    parser.add_argument("--replace", action="append", choices=FIXED, default=[])
    args = parser.parse_args()
    if not args.check and args.destination is None:
        parser.error("destination is required unless --check is set")
    try:
        identity = (IDENTITY_SENTENCE if args.check else
                    args.identity_file.read_bytes() if args.identity_file else None)
        items = replacements(identity, list(FIXED) if args.check else args.replace)
        result, errors = patch(args.source.read_bytes(), items)
        for error in errors:
            print(f"FAIL: kiro-bundle-patch: {error}" if args.check else
                  f"WARNING: kiro-bundle-patch: {error}; replacement skipped", file=sys.stderr)
        if args.check:
            if errors:
                return 1
            print("PASS: " + ", ".join(name for name, _, _ in items) + " exact sources each occur once")
        elif result is None:
            return 1
        else:
            args.destination.write_bytes(result)
    except (OSError, ValueError) as exc:
        print(f"WARNING: kiro-bundle-patch: {exc}; launching unpatched", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

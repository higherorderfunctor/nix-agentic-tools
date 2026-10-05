"""Apply named exact-byte replacements to Kiro's extracted KAS bundle.

Both launch and CI require each selected source to occur exactly once. CI
checks both sources; launch warns and returns nonzero so the wrapper can start
Kiro with its original bundle. No JavaScript parsing or steering decoding is
needed: the sources below are the pinned bundle's literal bytes.
"""

import argparse
from pathlib import Path
import sys

IDENTITY_SENTENCE = b"You are Kiro CLI, an agentic AI software engineer that runs in the command line."
WORKTREE_PARAGRAPH = b"When a task should run in a worktree, the **workflow owns the worktree setup** \\u2014 do NOT create the worktree yourself. Say in the `workflowPrompt` brief that a worktree is needed and let the generated workflow\\'s first step create it (`git worktree add .worktrees/<name> -b <branch> mainline`) and run all later steps targeting that worktree. Derive a descriptive `<name>`/`<branch>` from the task. The workflow\\'s final step rebases the branch onto `mainline` and fast-forwards `mainline`; you remove the worktree and branch after the run completes (an in-worktree step can\\'t safely delete the directory it is running in).\\n\\n"


def replacements(identity=None, strip_worktree=False):
    items = []
    if identity is not None:
        identity = identity.strip()
        if not identity or identity[-1:] not in (b".", b"!", b"?"):
            raise ValueError("identity: replacement must end with sentence punctuation (. ! ?)")
        if b"`" in identity or b"${" in identity:
            raise ValueError("identity: replacement may not contain a backtick or `${`")
        items.append(("identity", IDENTITY_SENTENCE, identity))
    if strip_worktree:
        items.append(("worktree", WORKTREE_PARAGRAPH, b""))
    return items


def patch(data, items):
    """Validate every source against the original bytes, then return the patch."""
    errors = []
    result = data
    for name, source, replacement in items:
        count = data.count(source)
        if count != 1:
            errors.append(f"{name}: expected exact source text once, found {count}; bundle drift")
        else:
            result = result.replace(source, replacement, 1)
    if errors:
        raise ValueError("; ".join(errors))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--identity-file", type=Path)
    parser.add_argument("--strip-worktree-steering", action="store_true")
    args = parser.parse_args()
    if not args.check and args.destination is None:
        parser.error("destination is required unless --check is set")
    try:
        identity = (IDENTITY_SENTENCE if args.check else
                    args.identity_file.read_bytes() if args.identity_file else None)
        items = replacements(identity, args.check or args.strip_worktree_steering)
        result = patch(args.source.read_bytes(), items)
        if args.check:
            print("PASS: identity and worktree exact sources each occur once")
        else:
            args.destination.write_bytes(result)
    except (OSError, ValueError) as exc:
        print(f"WARNING: kiro-bundle-patch: {exc}; launching unpatched", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

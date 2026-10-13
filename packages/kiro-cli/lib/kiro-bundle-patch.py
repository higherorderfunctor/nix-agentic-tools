"""Patch uniquely selected decoded AST chunks; preserve interpolation and other bytes."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

WORKTREE_PARAGRAPH = "When a task should run in a worktree, the **workflow owns the worktree setup** — do NOT create the worktree yourself. Say in the `workflowPrompt` brief that a worktree is needed and let the generated workflow's first step create it (`git worktree add .worktrees/<name> -b <branch> <base>`, where `<base>` is the branch checked out in the user's repo, which is not necessarily the default branch; name it in the brief) and run all later steps targeting that worktree. Derive a descriptive `<name>`/`<branch>` from the task. The workflow's final step rebases the branch onto `<base>` and fast-forwards `<base>` from the user's checkout (`git -C <repo> merge --ff-only <branch>`), because git will not move a branch that is checked out in another worktree; you remove the worktree and branch after the run completes (an in-worktree step can't safely delete the directory it is running in).\n\n"
FILE_CHECK_PARAGRAPH = '13. **Every path in a prompt or stop condition is absolute.** Step agents\' cwd is the parent session\'s workspace, not a worktree or subdirectory, so a relative path in a prompt silently resolves to the wrong place. Interpolate an input (e.g. `{{worktree_path}}/src/file.ts`) for every file a step reads, writes, or commits, and tell worktree steps to use `git -C <absolute worktree>` rather than describing the worktree as their "working directory". The same applies to `fileCheck.path` in a `stopCondition` or `completion`: relative paths resolve against the workflow\'s workspace root, and a path that never resolves evaluates false forever — the loop then spins to `maxIterations` instead of stopping.'
RELATIVE_FILE_CHECK_PARAGRAPH = '13. **Every path in a step prompt is absolute, except the stop-condition file.** Step agents\' cwd is the parent session\'s workspace, not a worktree or subdirectory, so a relative path in a prompt silently resolves to the wrong place. Interpolate an input (e.g. `{{worktree_path}}/src/file.ts`) for every other file a step reads, writes, or commits, and tell worktree steps to use `git -C <absolute worktree>` rather than describing the worktree as their "working directory". The file a `stopCondition` or `completion` checks is written by the step and checked by `fileCheck.path` at the same relative path: a plain path relative to the workflow workspace root (e.g. `.agents/tasks/review.json`), without templates or an absolute worktree prefix. Step agents\' cwd is that root, so the writing step and the check agree. A path that never resolves evaluates false forever — the loop then spins to `maxIterations` instead of stopping.'

FIXED = {
    "relativeFileCheckPaths": (FILE_CHECK_PARAGRAPH, RELATIVE_FILE_CHECK_PARAGRAPH),
    "stripVendorWorktreeSteering": (WORKTREE_PARAGRAPH, ""),
}


def replacements(names):
    return [(name, *FIXED[name]) for name in names]


def encode_chunk(raw, text):
    # Preserve the token's quote and template delimiters. JSON supplies JS-safe
    # escaping, with the extra escaping each JS delimiter requires.
    escaped = json.dumps(text, ensure_ascii=True)[1:-1]
    if raw[:1] in (b"'", b'"'):
        quote = raw[:1].decode()
        return (quote + escaped.replace("'", "\\'") + quote).encode()
    escaped = escaped.replace("`", "\\`").replace("${", "\\${")
    return raw[:1] + escaped.encode() + (b"${" if raw.endswith(b"${") else b"`")


def patch(data, corpus, items):
    """Refuse stale facts, tagged strings or missing/ambiguous decoded matches."""
    if hashlib.sha256(data).hexdigest() != corpus["sourceSha256"]:
        return None, ["corpus does not describe the source bundle"]
    errors, edits = [], {}
    for name, source, replacement in items:
        hits = [(chunk, chunk["text"].count(source)) for chunk in corpus["chunks"] if source in chunk["text"]]
        count = sum(count for _, count in hits)
        if count != 1:
            errors.append(f"{name}: expected decoded source text once, found {count}; bundle drift")
            continue
        chunk = hits[0][0]
        if chunk.get("tagged"):
            errors.append(f"{name}: tagged template has runtime-defined decoding")
            continue
        key = (chunk["start"], chunk["end"])
        text = edits.get(key, chunk["text"])
        edits[key] = text.replace(source, replacement, 1)
    if errors:
        return None, errors
    for (start, end), text in sorted(edits.items(), reverse=True):
        data = data[:start] + encode_chunk(data[start:end], text) + data[end:]
    return data, []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--replace", action="append", choices=FIXED, default=[])
    args = parser.parse_args()
    if not args.check and args.destination is None:
        parser.error("destination is required unless --check is set")
    try:
        items = replacements(list(FIXED) if args.check else args.replace)
        result, errors = patch(args.source.read_bytes(), json.loads(args.corpus.read_text()), items)
        for error in errors:
            print(f"FAIL: kiro-bundle-patch: {error}", file=sys.stderr)
        if errors:
            return 1
        if args.check:
            print("PASS: " + ", ".join(name for name, _, _ in items) + " decoded sources each occur once")
        else:
            args.destination.write_bytes(result)
    except (OSError, ValueError) as exc:
        print(f"FAIL: kiro-bundle-patch: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

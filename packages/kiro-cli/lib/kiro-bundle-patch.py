"""Compile named edits to Kiro's workflow prompts and splice them into the KAS bundle.

Input: the bundle, the extractor's text-mode facts (`extract/prompts.mjs`, run once on
the ORIGINAL bytes), the selected tweak names, and optionally a consumer's `prompts`
entries (`{key: {target, match, replace}}`, edit id `prompts.<key>`). Output: the bundle with each
edited prompt's literal replaced, and optionally the three original prompts as
plain text files. `lib/kas.nix` calls it at build time.

An edit selects text in ONE prompt's decoded body, so equal text in another
prompt never satisfies it. Every edit is validated first (one non-empty match, no
digest drift, no two edits intersecting); any failure refuses the whole build and
names the edits, never the vendor text. An edited prompt's whole literal is then
rewritten as a double-quoted JSON string, which JavaScript reads as the same
value; unedited prompts and every byte outside the literals stay as they were.

A replacement that names `{{primary}}` or `{{repo}}` cannot be settled at build
time, because those come from each session's checkout. Its edit is validated like
the rest, but instead of being spliced it becomes an `[original, replacement]`
fragment in `prompt-fragments.json`, and the two readers of the prompts call
`src/session-prompts.mjs` to apply it per session before Kiro renders the text.
"""

import argparse
from dataclasses import dataclass
import hashlib
import itertools
import json
from pathlib import Path
import re
import shutil
import sys

CREATOR = "agents.workflow.creator"
ORCHESTRATION = "workflow.orchestration"
PLANNER = "agents.workflow.planner"
# What the session fill looks a prompt up by: the agent id Kiro registers it under,
# or the leaf name for the steering block.
SESSION_KEYS = {CREATOR: "wf-workflow-creator", PLANNER: "wf-planner", ORCHESTRATION: ORCHESTRATION}
PLACEHOLDER = re.compile(r"\{\{(?:primary|repo)\}\}")
SESSION_MODULES = ("repo-root.mjs", "session-prompts.mjs")
# Static imports hoist, so the line sits below the bundle's shebang.
SESSION_IMPORT = b'import{fillAgentDefinition as __kiroFillAgent,fillPrompt as __kiroFillPrompt}from"./session-prompts.mjs";\n'


@dataclass(frozen=True)
class Edit:
    """Replace the one `match` in `leaf`, or with `until` the text from `match` through `until`.

    A span edit pins the SHA-256 of the whole selected text, so vendor wording
    changing inside two short anchors still refuses the build.
    """

    id: str
    leaf: str
    match: str
    replace: str
    until: str = ""
    sha256: str = ""

    @property
    def per_session(self):
        """True when the replacement can only be completed from a session's checkout."""
        return PLACEHOLDER.search(self.replace) is not None


GATE_FILE = "/repo/.agents/tasks/fix-throttle/review.json"
RELATIVE_GATE_FILE = ".agents/tasks/fix-throttle/review.json"
# The creator's worked example names its gate file at each site; the tweak moves
# all four so the example obeys the rule above it.
GATE_SITES = {
    "artifact-map": '"artifacts": { "review": "%s" }',
    "exists-sentence": "If %s exists",
    "stop-condition": '"stopCondition": { "fileCheck": { "path": "%s"',
    "then-sentence": "then %s as",
}
# Our authored text; the stop-condition file is the one path that stays relative.
RELATIVE_PARAGRAPH = (
    "5. **Every path in a step prompt is absolute, except the stop-condition file.** "
    "Step agents run in the parent session's workspace, not in a worktree, so write every other file a step "
    "reads, writes, or commits as a literal absolute path, and tell worktree steps to use "
    "`git -C <absolute worktree>`. The file a `stopCondition` or `completion` checks is written by the step "
    "and checked by `fileCheck.path` at the same relative path: a plain path relative to the workflow "
    "workspace root (e.g. `.agents/tasks/review.json`), without templates or an absolute worktree prefix. "
    "Step agents' cwd is that root, so the writing step and the check agree. "
    "A `fileCheck.path` that never resolves spins the loop to `maxIterations`."
)
# Built-in edits keyed by their `ai.kiro.cli.tweaks` option name; each id is `<tweak>.<edit>`.
TWEAKS = {
    "relativeFileCheckPaths": tuple(sorted((
        Edit(
            "relativeFileCheckPaths.gate-sentence",
            CREATOR,
            "names the gate file's absolute path in its prompt",
            "names the gate file's workspace-relative path, the one `fileCheck.path` checks, in its prompt",
        ),
        Edit(
            "relativeFileCheckPaths.paragraph",
            CREATOR,
            "5. **Every path is absolute**",
            RELATIVE_PARAGRAPH,
            until="Tell worktree steps to use `git -C <absolute worktree>`.",
            sha256="c4db123d14e3eeb577edcc007c45d69fcc04ecd225534abd119db4b6ce703719",
        ),
        *(
            Edit(f"relativeFileCheckPaths.{name}", CREATOR, site % GATE_FILE, site % RELATIVE_GATE_FILE)
            for name, site in GATE_SITES.items()
        ),
    ), key=lambda edit: edit.id)),
    "stripVendorWorktreeSteering": (
        Edit(
            "stripVendorWorktreeSteering.worktree-paragraph",
            ORCHESTRATION,
            "When a task should run in a worktree, say so",
            "",
            until="Do not create the worktree yourself.\n\n",
            sha256="79084f434d7078db84ce489c5b06756effd0fffa5014dc8ddbe45e20e64467b6",
        ),
    ),
}

def occurrences(text, needle):
    """Start offsets of every occurrence of a non-empty needle, overlapping ones included."""
    found, at = [], text.find(needle) if needle else -1
    while at >= 0:
        found.append(at)
        at = text.find(needle, at + 1)
    return found


def select(edit, text):
    """Return the edit's (start, end) in the decoded text, or an error naming the edit."""
    def miscount(what, found):
        return f"{edit.id}: expected exactly one {what} in {edit.leaf}, found {found}"

    starts = occurrences(text, edit.match)
    if len(starts) != 1:
        return miscount("match", len(starts))
    start = starts[0]
    if not edit.until:
        return start, start + len(edit.match)
    ends = occurrences(text, edit.until)
    if len(ends) != 1:
        return miscount("end anchor", len(ends))
    end = ends[0] + len(edit.until)
    if ends[0] < start + len(edit.match):
        return f"{edit.id}: the end anchor does not follow the match"
    if hashlib.sha256(text[start:end].encode()).hexdigest() != edit.sha256:
        return f"{edit.id}: the selected text differs from its pinned digest"
    return start, end


def patch(bundle, facts, edits):
    """Return (patched bytes, []) or (None, errors); validation completes before any splice."""
    errors = []
    for name, fact in facts.items():
        literal = bundle[fact["start"] : fact["end"]]
        if literal[:1] not in (b'"', b"'", b"`") or literal[-1:] != literal[:1]:
            errors.append(f"leaf {name}: the extracted fact does not match the bundle")
    ids = [edit.id for edit in edits]
    errors += [f"{name}: named by more than one edit" for name in sorted(set(ids)) if ids.count(name) > 1]
    chosen = []
    for edit in edits:
        fact = facts.get(edit.leaf)
        selection = select(edit, fact["text"]) if fact else f"{edit.id}: unknown leaf {edit.leaf}"
        if isinstance(selection, str):
            errors.append(selection)
        else:
            chosen.append((edit, *selection))
    for (a, a_start, a_end), (b, b_start, b_end) in itertools.combinations(chosen, 2):
        if a.leaf == b.leaf and a_start < b_end and b_start < a_end:
            errors.append(f"{a.id} and {b.id}: selections intersect in {a.leaf}")
    texts = {}
    for edit, start, end in sorted(chosen, key=lambda item: item[1], reverse=True):
        if not edit.per_session:
            text = texts.get(edit.leaf, facts[edit.leaf]["text"])
            texts[edit.leaf] = text[:start] + edit.replace + text[end:]
    for edit, start, end in chosen:
        if edit.per_session:
            original = facts[edit.leaf]["text"]
            errors += session_refusals(edit, original[start:end], texts.get(edit.leaf, original))
    if errors:
        return None, errors
    patched = bundle
    for name in sorted(texts, key=lambda name: facts[name]["start"], reverse=True):
        fact = facts[name]
        patched = patched[: fact["start"]] + json.dumps(texts[name], ensure_ascii=True).encode() + patched[fact["end"] :]
    return patched, []


def front_matter(text):
    """The leading `---` block of an agent prompt, or an empty string."""
    end = text.find("\n---\n", 4) if text.startswith("---\n") else -1
    return text[: end + 5] if end >= 0 else ""


# What JavaScript's `String.prototype.trim` strips; Python's `str.strip()` differs at the margins.
JS_SPACE = "".join(map(chr, (*range(9, 14), 32, 0xA0, 0x1680, *range(0x2000, 0x200B), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF)))


def reader_text(leaf, text):
    """The text the readers search: steering as written, an agent prompt as Kiro registers it (front matter removed, trimmed)."""
    return text if leaf == ORCHESTRATION else text[len(front_matter(text)) :].strip(JS_SPACE)


def session_refusals(edit, selected, text):
    """Errors for a per-session edit the readers could not find again.

    `text` is the leaf after the build-time edits; the readers must find the match once in `reader_text`.
    """
    if len(occurrences(reader_text(edit.leaf, text), selected)) != 1:
        return [f"{edit.id}: a {{{{primary}}}} or {{{{repo}}}} replacement must select text that appears once in what Kiro reads of {edit.leaf} (an agent's trimmed body, after the other edits)"]
    return []


def session_fragments(facts, edits):
    """`{reader key: [[original text, replacement], ...]}` for the per-session edits `patch` validated."""
    table = {}
    for edit in sorted((edit for edit in edits if edit.per_session), key=lambda edit: edit.id):
        start, end = select(edit, facts[edit.leaf]["text"])
        table.setdefault(SESSION_KEYS[edit.leaf], []).append([facts[edit.leaf]["text"][start:end], edit.replace])
    return table


def once(bundle, pattern, what):
    """The only match of `pattern` in the bundle; a Kiro release that moved it refuses the build."""
    found = list(re.finditer(pattern, bundle))
    if len(found) != 1:
        raise ValueError(f"expected exactly one {what} in the bundle, found {len(found)}")
    return found[0]


def hook_readers(bundle, orchestration_binding, table):
    """Route the readers of the prompts through `src/session-prompts.mjs`; return the new bundle.

    Agent prompts are read by Kiro's `subagentPrompt`, which the session and the
    subagent paths both call with the session's workspace. The orchestration
    steering is read where the conversation's blocks are assembled, with the
    session state in hand. Variable names are minified and change per release; the
    registered function name and the async method name do not, so they locate the sites.
    """
    top = bundle.index(b"\n") + 1
    splices = [(top, top, SESSION_IMPORT)]
    if any(key != ORCHESTRATION for key in table):
        registered = once(bundle, rb'[\w$]+\(([\w$]+),"subagentPrompt"\)', "subagentPrompt registration")
        header = once(bundle, rb"async function " + re.escape(registered[1]) + rb"\(([\w$]+),[\w$]+,([\w$]+)\)\{", "subagentPrompt function")
        splices.append((header.end(), header.end(), b"%s=await __kiroFillAgent(%s,%s);" % (header[1], header[1], header[2])))
    if ORCHESTRATION in table:
        site = once(bundle, rb"\{text:" + re.escape(orchestration_binding) + rb',kind:"kiro"\}', "orchestration steering block")
        method = once(bundle, rb"async createDefinitionForMode\(([\w$]+)[,)]", "createDefinitionForMode")
        if not 0 < site.start() - method.end() < 2048:
            raise ValueError("the orchestration steering block is not inside createDefinitionForMode")
        code = b'{text:await __kiroFillPrompt("%s",%s,%s.workspacePaths[0]),kind:"kiro"}'
        splices.append((site.start(), site.end(), code % (ORCHESTRATION.encode(), orchestration_binding, method[1])))
    for start, end, code in sorted(splices, reverse=True):
        bundle = bundle[:start] + code + bundle[end:]
    return bundle


def binding_name(bundle, fact):
    """The variable a leaf's literal is assigned to, read from the bytes before it."""
    return once(bundle[max(0, fact["start"] - 64) : fact["start"]], rb"([\w$]+)=$", "assignment of a prompt literal")[1]


def export_leaves(facts, directory):
    """Write each original prompt, unescaped, to `<directory>/<leaf>.txt`."""
    directory.mkdir(parents=True, exist_ok=True)
    for name, fact in facts.items():
        (directory / f"{name}.txt").write_text(fact["text"], encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("facts", type=Path, help="text-mode output of extract/prompts.mjs for the source")
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true", help="validate every built-in edit; write nothing")
    parser.add_argument("--export-leaves", type=Path, help="directory for the original prompts as text")
    parser.add_argument("--prompts", type=Path, help="JSON object of consumer edits: {key: {target, match, replace}}")
    parser.add_argument("--replace", action="append", choices=TWEAKS, default=[])
    parser.add_argument("--session-fill", type=Path, help="directory of the session fill modules, installed beside the destination when an entry needs them")
    args = parser.parse_args()
    if not args.check and args.destination is None:
        parser.error("destination is required unless --check is set")
    if args.check and args.export_leaves:
        parser.error("--check writes nothing, so it cannot be combined with --export-leaves")
    if args.check and args.prompts:
        parser.error("--check validates the built-in edits only, so it cannot be combined with --prompts")
    names = list(TWEAKS) if args.check else sorted(set(args.replace))
    try:
        facts = json.loads(args.facts.read_text(encoding="utf-8"))
        entries = json.loads(args.prompts.read_text(encoding="utf-8")) if args.prompts else {}
        custom = [Edit(f"prompts.{key}", entry["target"], entry["match"], entry["replace"]) for key, entry in sorted(entries.items())]
        source = args.source.read_bytes()
        edits = [edit for name in names for edit in TWEAKS[name]] + custom
        result, errors = patch(source, facts, edits)
        table = {} if errors else session_fragments(facts, edits)
        if table and not args.check and args.session_fill is None:
            errors.append("--session-fill is required when an entry uses {{primary}} or {{repo}}")
        for error in errors:
            print(f"FAIL: kiro-bundle-patch: {error}", file=sys.stderr)
        if errors:
            return 1
        if args.export_leaves:
            export_leaves(facts, args.export_leaves)
        if args.check:
            print("PASS: " + ", ".join(names) + " edits each select one unchanged span")
        else:
            if table:
                binding = binding_name(source, facts[ORCHESTRATION]) if ORCHESTRATION in table else None
                result = hook_readers(result, binding, table)
                for module in SESSION_MODULES:
                    shutil.copy(args.session_fill / module, args.destination.parent / module)
                (args.destination.parent / "prompt-fragments.json").write_text(json.dumps(table), encoding="utf-8")
            args.destination.write_bytes(result)
    except (KeyError, OSError, TypeError, ValueError) as exc:
        print(f"FAIL: kiro-bundle-patch: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

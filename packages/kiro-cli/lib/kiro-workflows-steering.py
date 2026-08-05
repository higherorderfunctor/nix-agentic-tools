"""Extract the vendor's `workflows_default` steering text from a KAS bundle.

When `workflowsEnabled` is set, the engine appends this block to the system
prompt (`createDefinitionForMode`), so it is already in msg0 from turn one --
and msg0 is FROZEN, replayed byte-for-byte on every later turn. Nothing about it
decays.

What decays is ATTENTION. One block near the top of a growing context competes
with everything since, which is why a per-turn `UserPromptSubmit` reminder works
where more steering does not: the reminder buys POSITION, not content.

That is also why the reminder should be short. This extractor exists so the full
text can be READ (and optionally injected by a caller who has decided to pay for
it), not because re-injecting ~4.8k tokens every turn is a good idea.

Usage:  kiro-workflows-steering.py <bundle>            # decoded text on stdout
        kiro-workflows-steering.py <bundle> --stats    # size only, no body
"""

import re
import sys

# `var workflows_default = '...'` -- esbuild inlines the steering markdown as a
# single-quoted JS literal with escaped newlines. The name is a module-level
# binding derived from the source FILENAME (`src/steering/workflows.md`), which
# is why it survives the collision suffixes that churn on ordinary identifiers.
ASSIGN = re.compile(rb"var workflows_default = '")


def die(msg):
    sys.stderr.write("kiro-workflows-steering: %s\n" % msg)
    sys.exit(1)


def extract(data):
    hits = list(ASSIGN.finditer(data))
    if len(hits) != 1:
        die(
            "expected exactly one `var workflows_default = '` assignment, found "
            "%d. The steering module was restructured or the literal is no "
            "longer single-quoted; re-locate it rather than guessing." % len(hits)
        )

    # Walk the literal by hand rather than with a regex: the body contains
    # escaped quotes (`\'`) and a greedy/lazy pattern gets either the whole file
    # or a truncated prefix, both of which look plausible.
    i = hits[0].end()
    out = bytearray()
    while True:
        if i >= len(data):
            die("unterminated workflows_default literal")
        c = data[i : i + 1]
        if c == b"\\":
            out += data[i : i + 2]
            i += 2
            continue
        if c == b"'":
            break
        out += c
        i += 1

    text = out.decode("utf-8").encode().decode("unicode_escape")

    # Shape assertion, not a non-empty guard. A dead anchor that matched some
    # other string would still produce "something", and the failure would then
    # surface as a reminder full of unrelated text rather than as an error.
    if not text.lstrip().startswith("#"):
        die("extracted text is not the expected markdown steering block")
    for marker in ("workflow", "run_workflow"):
        if marker not in text:
            die("extracted text lacks %r -- wrong literal captured" % marker)

    return text


def main(argv):
    if len(argv) not in (2, 3):
        die("usage: %s <bundle> [--stats]" % argv[0])

    text = extract(open(argv[1], "rb").read())

    if len(argv) == 3 and argv[2] == "--stats":
        sys.stdout.write(
            "chars=%d lines=%d approx_tokens=%d\n"
            % (len(text), text.count("\n") + 1, len(text) // 4)
        )
        return

    sys.stdout.write(text)


if __name__ == "__main__":
    main(sys.argv)

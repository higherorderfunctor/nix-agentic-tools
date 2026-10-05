"""Extract the vendor's workflow-orchestration steering text from a KAS bundle.

When `workflowsEnabled` is set, the engine appends this block to the system
prompt (`createDefinitionForMode`), so it is already in msg0 from turn one --
and msg0 is FROZEN, replayed byte-for-byte on every later turn. Nothing about it
decays.

What decays is ATTENTION. One block near the top of a growing context competes
with everything since, which is why a per-turn `UserPromptSubmit` reminder works
where more steering does not: the reminder buys POSITION, not content.

That is also why the reminder should be short. This extractor exists so the full
text can be READ (and optionally injected by a caller who has decided to pay for
it), not because re-injecting thousands of tokens every turn is a good idea.

Usage:  kiro-workflows-steering.py <bundle>            # decoded text on stdout
        kiro-workflows-steering.py <bundle> --stats    # size only, no body
"""

# cspell:ignore bfnrtv  (JavaScript escape letters, not project vocabulary)
import ast
import re
import sys

# Bindings have been minified since at least 2.21.4. Match the content instead.
HEADING = b"# Workflow Orchestration"
ANCHOR = re.compile(rb"'" + re.escape(HEADING))
ESCAPE = re.compile(r"\\(?:['\\bfnrtv]|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4})")


def die(msg):
    sys.stderr.write("kiro-workflows-steering: %s\n" % msg)
    sys.exit(1)


def extract(data):
    hits = list(ANCHOR.finditer(data))
    if len(hits) != 1:
        die(
            "expected exactly one string literal beginning with %r, found %d. "
            "The steering text was retitled, split, or duplicated; re-locate it "
            "rather than guessing." % (HEADING.decode(), len(hits))
        )

    # Walk the literal by hand rather than with a regex: the body contains
    # escaped quotes (`\'`) and a greedy/lazy pattern gets either the whole file
    # or a truncated prefix, both of which look plausible.
    i = hits[0].start() + 1
    out = bytearray()
    while True:
        if i >= len(data):
            die("unterminated steering literal")
        c = data[i : i + 1]
        if c == b"\\":
            out += data[i : i + 2]
            i += 2
            continue
        if c == b"'":
            break
        out += c
        i += 1

    # Decode the JS escapes with `ast.literal_eval`, not `unicode_escape`.
    #
    # `unicode_escape` is a LATIN-1 codec: it decodes BYTES, so non-ASCII in the
    # literal survives only while esbuild happens to emit it as `\uXXXX`.
    # Measured on 2.16.0 it does (pure ASCII, 24 `\u` escapes), so the older
    # `.encode().decode("unicode_escape")` round-trip was correct HERE -- but
    # correct by luck, and the day esbuild emits a raw UTF-8 em dash it would
    # silently mojibake the reminder rather than fail.
    #
    # Normalizing into JSON was tried and is WRONG: a JS literal may contain
    # `\\"` (escaped backslash, then a bare quote), where a "quote not preceded
    # by a backslash" rule declines to escape the quote and JSON then terminates
    # the string early. Measured -- it died at char 937 of this very block.
    #
    # Accept only escapes whose JS and Python meanings agree. In particular,
    # Python accepts \a and \N{...}, and silently preserves an unknown \q.
    try:
        body = out.decode("utf-8")
        if "\\" in ESCAPE.sub("", body):
            die("unsupported escape in the steering literal")
        text = ast.literal_eval("'" + body + "'")
        if any(0xD800 <= ord(c) <= 0xDFFF for c in text):
            die("unpaired surrogate escape in the steering literal")
    except (UnicodeDecodeError, ValueError, SyntaxError) as exc:
        die("could not decode the steering literal: %s" % exc)

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

# cspell:ignore surrogatepass
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

import re
import sys

# Anchored on the steering CONTENT: the one JS string literal whose value starts
# with this heading. Not on the binding name. Through 2.16.x esbuild named it
# `var workflows_default = '...'` after the source file; 2.27.1 ships a minified
# bundle where the same literal is `var Dho='...'`, and the name-anchored regex
# found nothing. A minifier renames bindings freely; it does not edit strings.
HEADING = b"# Workflow Orchestration"
QUOTES = b"'\"`"
ANCHOR = re.compile(b"[" + re.escape(QUOTES) + b"]" + re.escape(HEADING))

# JS single-character escapes. Any other escaped character that is not handled
# below (`\'`, `\"`, `\\`, `\q`) is the character itself.
SIMPLE = {"b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
LINE_TERMINATORS = "\n\r  "
HEX = "0123456789abcdefABCDEF"


def die(msg):
    sys.stderr.write("kiro-workflows-steering: %s\n" % msg)
    sys.exit(1)


def hex_digits(body, i, count):
    digits = body[i : i + count]
    if count < 1 or len(digits) != count or any(c not in HEX for c in digits):
        die("malformed escape at offset %d of the steering literal" % i)
    return int(digits, 16)


def code_point(value):
    try:
        return chr(value)
    except ValueError:
        die("escape out of range in the steering literal")


def js_unescape(body):
    """Decode the body of a '...' or "..." JS string literal.

    Written out rather than borrowed from a Python decoder, because none of them
    has JS's escape set. `unicode_escape` is a LATIN-1 codec and garbles raw
    UTF-8; `ast.literal_eval` keeps the backslash of an unknown escape (`\\q`)
    and rejects `\\u{...}`; JSON rejects `\\'` and `\\x`.

    `\\uXXXX` yields UTF-16 code units, so a surrogate pair arrives as two lone
    surrogates; `surrogatepass` re-pairs them at the end.
    """
    out = []
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= n:
            die("steering literal ends in a bare backslash")
        c = body[i]
        i += 1
        if c in SIMPLE:
            out.append(SIMPLE[c])
        elif c == "x":
            out.append(code_point(hex_digits(body, i, 2)))
            i += 2
        elif c == "u" and body[i : i + 1] == "{":
            end = body.find("}", i)
            if end == -1:
                die("unterminated \\u{...} escape in the steering literal")
            out.append(code_point(hex_digits(body, i + 1, end - i - 1)))
            i = end + 1
        elif c == "u":
            out.append(code_point(hex_digits(body, i, 4)))
            i += 4
        elif c == "0" and not body[i : i + 1].isdigit():
            out.append("\0")
        elif c.isdigit():
            # Legacy octal (and `\8`, `\9`) is a syntax error in strict-mode
            # code, which esbuild emits. Seeing one means the scan went wrong.
            die("legacy octal escape \\%s in the steering literal" % c)
        elif c == "\r" and body[i : i + 1] == "\n":
            i += 1  # line continuation, CRLF
        elif c in LINE_TERMINATORS:
            pass  # line continuation
        else:
            out.append(c)
    try:
        return "".join(out).encode("utf-16", "surrogatepass").decode("utf-16")
    except UnicodeDecodeError:
        die("unpaired surrogate escape in the steering literal")


def extract(data):
    hits = list(ANCHOR.finditer(data))
    if len(hits) != 1:
        die(
            "expected exactly one string literal beginning with %r, found %d. "
            "The steering text was retitled, split, or duplicated; re-locate it "
            "rather than guessing." % (HEADING.decode(), len(hits))
        )
    start = hits[0].start()
    quote = data[start : start + 1]
    if quote == b"`":
        # A template literal can carry `${...}` substitutions, which no static
        # decoder can resolve. Fail rather than return text with holes in it.
        die("the steering literal is now a template literal; extend the decoder")

    # Walk the literal by hand rather than with a regex: the body contains
    # escaped quotes and a greedy/lazy pattern gets either the whole file or a
    # truncated prefix, both of which look plausible. Byte-wise is safe because
    # the quote and the backslash are ASCII, and UTF-8 never reuses an ASCII byte
    # inside a multi-byte sequence.
    i = start + 1
    while True:
        if i >= len(data):
            die("unterminated steering literal")
        c = data[i : i + 1]
        if c == b"\\":
            i += 2
            continue
        if c == quote:
            break
        if c in (b"\n", b"\r"):
            die("raw line break inside the steering literal; the scan went wrong")
        i += 1

    try:
        body = data[start + 1 : i].decode("utf-8")
    except UnicodeDecodeError as exc:
        die("steering literal is not valid UTF-8: %s" % exc)
    text = js_unescape(body)

    # Shape assertion, not a non-empty guard. A literal that merely starts with
    # the heading but is something else would still produce "something".
    if "run_workflow" not in text:
        die("extracted text lacks 'run_workflow' -- wrong literal captured")

    return text


def main(argv):
    if len(argv) not in (2, 3):
        die("usage: %s <bundle> [--stats]" % argv[0])

    try:
        with open(argv[1], "rb") as handle:
            data = handle.read()
    except OSError as exc:
        die("cannot read bundle: %s" % exc)
    text = extract(data)

    if len(argv) == 3 and argv[2] == "--stats":
        sys.stdout.write(
            "chars=%d lines=%d approx_tokens=%d\n"
            % (len(text), text.count("\n") + 1, len(text) // 4)
        )
        return

    sys.stdout.write(text)


if __name__ == "__main__":
    main(sys.argv)

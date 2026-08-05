"""Splice the kiro-cli identity sentence in an extracted KAS engine bundle.

The vendor's `getIdentity(client)` returns ONE template literal per client id.
For `kiro-cli` it opens with an identity sentence and continues with prose about
the terminal environment (no GUI, refer to files by path, ...). Only the leading
sentence is replaced; the remainder is preserved byte-for-byte, because it is
the part that keeps the agent behaving like a terminal program.

NOTHING here matches vendor prose. The anchor is built from a function name and
a protocol client id, and the sentence boundary is found by punctuation, so a
vendor reword still splices correctly. What the anchor cannot survive is a
STRUCTURAL change, and that is deliberately fatal rather than silent: a
half-applied or mis-targeted identity patch is worse than an unpatched engine,
since neither the CLI nor the session artifact would show which one you got.

Usage:  kiro-identity-splice.py <src-bundle> <dst-bundle> <replacement-file>
        kiro-identity-splice.py <src-bundle> --print

`--print` emits the current vendor sentence on stdout and patches nothing; it is
what lets a caller record what is being replaced.
"""

import re
import sys

# `client` picks up an esbuild collision suffix (`client2`, `client24`) that
# churns between releases, so the digits are matched rather than pinned.
FN = re.compile(rb"function getIdentity\(")
BRANCH = re.compile(rb'if \(client\d* === "kiro-cli"\) \{\s*\n\s*return `([^`]*)`')
NEXT_FN = re.compile(rb"\nfunction \w+\(")
# Sentence-ending punctuation plus the single separating space. The space is
# part of the match so the tail is sliced at `m.end()` and stays byte-for-byte
# identical to what followed it.
SENTENCE_END = re.compile(rb"[.!?] ")
# Siblings that must remain findable by the same method. Without them, "the
# branch is gone" and "my pattern no longer parses this file" are the same
# observation, and the second silently reads as the first.
#
# `kiro-ide` is the ONLY sibling in this function -- `kiro-web` branches inside
# getSessionTypes, several hundred bytes further on. Listing it here is exactly
# the mistake the window bound below prevents: a loose window picks it up and
# the control then passes for the wrong reason.
CONTROLS = (b"kiro-ide",)


def die(msg):
    sys.stderr.write("kiro-identity: %s\n" % msg)
    sys.exit(1)


def find_literal(data):
    """Return (abs_offset, body) for the kiro-cli identity template literal.

    Split out from `locate` so verification can compare the REASSEMBLED literal
    rather than re-deriving a "first sentence" from it. Those are not the same
    check once the replacement itself contains sentence punctuation, and
    conflating them silently broke every multi-sentence identity: the re-split
    yielded only the replacement's FIRST sentence, which never equalled the
    whole replacement, so a correct splice was reported as a failed one.
    """
    fns = list(FN.finditer(data))
    if len(fns) != 1:
        die(
            "expected exactly one `function getIdentity(`, found %d. The engine "
            "bundle's prompt module was restructured; re-locate the identity "
            "before shipping a patch." % len(fns)
        )

    start = fns[0].start()
    # Bound the window to this function only. A fixed-size window overruns into
    # getSessionTypes, which branches on the same client ids and would inflate
    # every count below.
    nxt = NEXT_FN.search(data, start + 1)
    window = data[start : nxt.start() if nxt else start + 8000]

    hits = list(BRANCH.finditer(window))
    if len(hits) != 1:
        die(
            "expected exactly one kiro-cli branch inside getIdentity, found %d. "
            "Refusing to patch: which branch feeds the session is not decidable "
            "from here." % len(hits)
        )

    for cid in CONTROLS:
        p = re.compile(rb'if \(client\d* === "' + cid + rb'"\) \{')
        n = len(p.findall(window))
        if n != 1:
            die(
                "positive control failed: the %s branch matched %d times inside "
                "getIdentity. The bundle shape moved, so a 'clean' kiro-cli match "
                "cannot be trusted either." % (cid.decode(), n)
            )

    return start + hits[0].start(1), hits[0].group(1)


def locate(data):
    """Return (abs_offset, first_sentence, tail) for the kiro-cli identity."""
    off, body = find_literal(data)
    # Any sentence-ending punctuation followed by exactly one space. Matching
    # only `". "` would silently refuse to patch if upstream ever ends the
    # identity with `!` or `?` -- and because the caller FAILS OPEN, that
    # refusal would present as "the option quietly stopped working" rather than
    # as an error anyone reads.
    m = SENTENCE_END.search(body)
    if not m:
        die(
            "the kiro-cli identity literal has no sentence boundary to split on. "
            "Upstream collapsed it to a single sentence; decide explicitly what "
            "'replace the first sentence' should now mean."
        )

    return off, body[: m.start() + 1], body[m.end() :]


def main(argv):
    if len(argv) == 3 and argv[2] == "--print":
        data = open(argv[1], "rb").read()
        sys.stdout.write(locate(data)[1].decode())
        return

    if len(argv) != 4:
        die("usage: %s <src> <dst> <replacement-file> | <src> --print" % argv[0])

    src, dst, repl_path = argv[1], argv[2], argv[3]
    data = open(src, "rb").read()
    off, first, tail = locate(data)

    replacement = open(repl_path, "rb").read().strip()
    if not replacement:
        die("replacement sentence is empty; refusing to blank the identity")
    # A backtick or `${` would terminate the template literal or open an
    # interpolation, producing a syntactically broken bundle that fails at
    # engine spawn with a stack trace pointing at vendor code.
    if b"`" in replacement or b"${" in replacement:
        die("replacement may not contain a backtick or `${` (breaks the JS literal)")
    # The literal is reassembled as `replacement + " " + tail`, so a replacement
    # that does not close its own final sentence MERGES into the preserved
    # vendor text ("You are GLaDOS You operate in a terminal environment: ...")
    # and the splice stops meaning "replace the first sentence".
    #
    # The `find_literal` verification below cannot catch this: the reassembled
    # literal is byte-for-byte what was asked for, it simply no longer has a
    # sentence boundary where one is required.
    #
    # BACKSTOP ONLY -- the primary gate is a module assertion in mkKiro.nix that
    # fires at EVAL. This path fails open, so a value rejected here presents as
    # a silently unpatched identity rather than as a configuration error.
    if replacement[-1:] not in (b".", b"!", b"?"):
        die(
            "replacement must end with sentence punctuation (. ! ?); it would "
            "otherwise run into the preserved vendor text instead of replacing "
            "a sentence. Got: ...%s"
            % replacement[-40:].decode("utf-8", "replace")
        )

    patched = data[:off] + replacement + b" " + tail + data[off + len(first) + 1 + len(tail) :]

    with open(dst, "wb") as fh:
        fh.write(patched)

    # Re-read and re-locate: proves the written bundle still parses under the
    # same anchor and now carries the replacement, rather than trusting the
    # arithmetic above.
    #
    # Compare the whole reassembled literal, NOT a re-derived "first sentence".
    # The replacement may itself contain sentence punctuation -- a multi-sentence
    # identity is a supported and expected use -- and re-splitting would then
    # yield only its first sentence and fail every such splice. That is not
    # hypothetical: it rejected every multi-sentence identity while single
    # sentence ones passed, so the option appeared to work for some values and
    # silently fall back to stock for others.
    check = open(dst, "rb").read()
    _, new_body = find_literal(check)
    expected = replacement + b" " + tail
    if new_body != expected:
        die(
            "verification failed: the spliced literal does not match "
            "replacement + tail (got %d bytes, expected %d)"
            % (len(new_body), len(expected))
        )

    sys.stderr.write(
        "kiro-identity: spliced (%d -> %d bytes), %d-byte tail preserved\n"
        % (len(first), len(replacement), len(tail))
    )


if __name__ == "__main__":
    main(sys.argv)

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


def locate(data):
    """Return (abs_offset, first_sentence, tail) for the kiro-cli identity."""
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

    body = hits[0].group(1)
    try:
        idx = body.index(b". ")
    except ValueError:
        die(
            "the kiro-cli identity literal has no sentence boundary to split on. "
            "Upstream collapsed it to a single sentence; decide explicitly what "
            "'replace the first sentence' should now mean."
        )

    first = body[: idx + 1]
    tail = body[idx + 2 :]
    return start + hits[0].start(1), first, tail


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

    patched = data[:off] + replacement + b" " + tail + data[off + len(first) + 1 + len(tail) :]

    with open(dst, "wb") as fh:
        fh.write(patched)

    # Re-read and re-locate: proves the written bundle still parses under the
    # same anchor and now carries the replacement, rather than trusting the
    # arithmetic above.
    check = open(dst, "rb").read()
    _, new_first, new_tail = locate(check)
    if new_first != replacement:
        die("verification failed: spliced sentence is not the requested one")
    if new_tail != tail:
        die("verification failed: the preserved tail was altered")

    sys.stderr.write(
        "kiro-identity: spliced (%d -> %d bytes), %d-byte tail preserved\n"
        % (len(first), len(replacement), len(tail))
    )


if __name__ == "__main__":
    main(sys.argv)

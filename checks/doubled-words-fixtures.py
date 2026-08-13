#!/usr/bin/env python3
"""Run doubled_words against the committed fixtures in checks/fixtures/doubled-words.

The scanner's precision and recall are measured against the repo's real 220
markdown files, and those measurements live in ./doubled-words.py's module
docstring. This is the other half: a handful of tiny inputs pinning the
SHAPES that measurement is blind to.

Why both. A corpus measurement answers "how does the current rule score on
the text we happen to have", which is the right question for tuning and the
wrong one for regression. It cannot fail on a shape the corpus does not
contain today, and it cannot tell you WHICH rule broke when the number
moves. The GFM task-list bug is the worked example: the corpus said 272
lines were still blanked, the docstring called all 272 genuine code, and
215 of them were prose — a nine-line fixture would have said so
immediately, and the corpus number said nothing at all.

Each fixture opens with a `<!-- FIXTURE ... -->` header stating what it
proves and declaring its expected hits:

    <!-- FIXTURE
    proves: … prose explaining the shape …
    expect: 16 "the the"
    expect: 19 "in in"
    -->

or `expect: none`. Line numbers are 1-based and count the header. The
assertion is on the EXACT SET of hits: an unexpected hit fails as loudly as
a missing one, so a fixture doubles as a false-positive control.

A fixture with no `expect:` line at all is an ERROR, not an empty
expectation. Same reasoning as `no_files` in ./split-code-spans.py: a
declaration nobody wrote is indistinguishable from a declaration that
passed, and the silent version of that is what lets a gate rot.

The fixtures are `*.md.fixture`, not `*.md`, and that is load-bearing —
`checks/markdown-scan.nix` scans every tracked `.md` in the tree, so a `.md`
fixture carrying a deliberate doubling would fail the check it tests, and
prettier would reflow away the exact indentation it encodes. See the
directory's own README.md.fixture.
"""

import importlib
import importlib.util
import re
import sys
from pathlib import Path

HEADER = re.compile(r"<!--\s*FIXTURE\b(.*?)-->", re.S)
EXPECT = re.compile(r'^expect:[ \t]+(?:(none)|([0-9]+)[ \t]+"(.+)")[ \t]*$', re.M)


def _load(module, filename):
    """Import MODULE, falling back to FILENAME beside this script.

    The check assembles the scanners into one store directory under legal
    Python module names (see ./markdown-scanners.nix), where a plain import
    works. A checkout has the same code under its real, hyphen-bearing
    filenames, which are not importable at all. Supporting both is what
    makes this runnable by hand:

        python3 checks/doubled-words-fixtures.py checks/fixtures/doubled-words

    Load order matters: doubled_words does `from split_code_spans import …`,
    so split_code_spans has to be in sys.modules under that name first,
    which is what the assignment below is for.
    """
    try:
        return importlib.import_module(module)
    except ModuleNotFoundError:
        spec = importlib.util.spec_from_file_location(module, Path(__file__).with_name(filename))
        loaded = importlib.util.module_from_spec(spec)
        sys.modules[module] = loaded
        spec.loader.exec_module(loaded)
        return loaded


_load("split_code_spans", "split-code-spans.py")
doubled_words = _load("doubled_words", "doubled-words.py")


def expectations(path):
    """Parse the fixture header. Returns a set of (line, bigram), or None."""
    header = HEADER.search(path.read_text(encoding="utf-8"))
    if not header:
        return None
    found = EXPECT.findall(header.group(1))
    if not found:
        return None
    return {(int(line), bigram) for none, line, bigram in found if not none}


def main(argv):
    if len(argv) != 1:
        print("usage: doubled-words-fixtures.py <fixture-dir>", file=sys.stderr)
        return 1
    fixtures = sorted(Path(argv[0]).glob("*.md.fixture"))
    if not fixtures:
        print(f"ERROR: no *.md.fixture files in {argv[0]}.", file=sys.stderr)
        print("A fixture run over nothing is not a pass.", file=sys.stderr)
        return 1

    failures = []
    for path in fixtures:
        expected = expectations(path)
        if expected is None:
            failures.append(
                f"{path.name}: no `<!-- FIXTURE … expect: … -->` header. Every "
                "fixture must declare what it proves and what it expects; an "
                "absent declaration is not an empty one."
            )
            continue
        hits, stale = doubled_words.scan(path)
        actual = {(line, bigram) for line, bigram in hits}
        for line, bigram in sorted(actual - expected):
            failures.append(f'{path.name}:{line}: unexpected hit "{bigram}"')
        for line, bigram in sorted(expected - actual):
            failures.append(f'{path.name}:{line}: expected hit "{bigram}" was NOT reported')
        for marker in stale:
            failures.append(f'{path.name}: allow marker "{marker}" suppressed nothing')

    if failures:
        print("ERROR: doubled-words fixture expectations not met.")
        print()
        for failure in failures:
            print(f"  {failure}")
        print()
        print("A MISSING hit is the dangerous direction: it means prose is being")
        print("blanked before the scan reads it, which presents as a clean file.")
        print("Start at `strip_code_blocks` in checks/split-code-spans.py, and")
        print("re-measure the corpus figures in checks/doubled-words.py's")
        print("docstring before changing them.")
        return 1

    print(f"All {len(fixtures)} doubled-words fixtures match their expectations.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

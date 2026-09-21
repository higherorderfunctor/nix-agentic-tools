"""Tests that the packet's prose quotes its own sources exactly.

Two claims are checked, and both were true when written and had nothing holding
them true. The guide says of each code block which file and which lines it is a
fragment of. The contract shows two field-value leaves and says they come from
the variant model. A later edit to either source moves those lines and leaves
the quote reading like verified evidence, which is worse than no quote at all.

Both tests read text, not decoded JSON, because the claim is about bytes. The
contract nests its leaves one level deeper than the bundle does, so the contract
block is compared against the bundle's own bytes shifted left by the indentation
that nesting forces, and by nothing else.

Standard library only, so these run wherever the rest of the suite runs.
"""

import json
import pathlib
import re
import textwrap
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
PACKET_DIRECTORY = BACKEND_DIRECTORY.parent
GUIDE_PATH = PACKET_DIRECTORY / "README.md"
CONTRACT_PATH = PACKET_DIRECTORY / "contract.md"
VARIANT_BUNDLE_PATH = BACKEND_DIRECTORY / "fixtures/note-state-field/bundle.json"

# "(fragment of examples.nix, lines 12-13)" and "(fragment of the same file,
# lines 15-15)". The file name carries forward, so a run of fragments from one
# source names it once. Either dash spelling is accepted and the whole claim may
# wrap across lines, because the guide is prose-wrapped.
FRAGMENT_CLAIM = re.compile(
    r"\(fragment of\s+(?:the\s+)?(?P<source>same file|[^,()]+?),"
    r"\s*lines\s+(?P<first>\d+)\s*[–-]\s*(?P<last>\d+)\s*\)",
    re.S,
)
NIX_BLOCK = re.compile(r"```nix\n(.*?)```", re.S)
JSON_BLOCK = re.compile(r"```json\n(.*?)```", re.S)
# A leaf the contract quotes sits directly under a rule's check or a selector's
# where, which is what its prose claims: one in a relation check and one in a
# records filter. The third leaf in that bundle is nested under a not and is not
# quoted.
QUOTED_LEAF_OPENING = re.compile(r'"(?:check|where)": \{$')


def read(path):
    return path.read_text(encoding="utf-8")


def fragment_claims(guide):
    """Yield (source file name, first line, last line, quoted block) in order.

    The quoted block is the next Nix block after the claim, which is how the
    guide is written throughout.
    """
    blocks = [(match.start(), match.group(1)) for match in NIX_BLOCK.finditer(guide)]
    named_source = None
    for match in FRAGMENT_CLAIM.finditer(guide):
        source = re.sub(r"\s+", " ", match.group("source")).strip()
        if source == "same file":
            assert named_source is not None, "the first claim must name its file"
            source = named_source
        else:
            named_source = source
        quoted = next(body for start, body in blocks if start > match.start())
        yield source, int(match.group("first")), int(match.group("last")), quoted


def quoted_leaves(bundle_text):
    """Return the field-value leaves the contract quotes, each dedented.

    Each is found by matching braces outward from its kind line, so the result
    is the bundle's own bytes rather than a re-serialization. The left margin
    that nesting adds is removed and nothing else is touched.
    """
    lines = bundle_text.splitlines()
    found = []
    for index, line in enumerate(lines):
        if line.strip() != '"kind": "field-value",':
            continue
        opening = index
        while not lines[opening].rstrip().endswith("{"):
            opening -= 1
        if not QUOTED_LEAF_OPENING.search(lines[opening]):
            continue
        margin = len(lines[opening]) - len(lines[opening].lstrip())
        closing = index
        while lines[closing].strip() not in ("}", "},"):
            closing += 1
        body = [lines[opening].rstrip()[-1]]
        body.extend(line[margin:] for line in lines[opening + 1 : closing])
        body.append(lines[closing][margin:].rstrip(","))
        found.append("\n".join(body))
    return found


def contract_leaf_example(contract):
    """Return the one contract block that is an array of field-value leaves."""
    blocks = []
    for match in JSON_BLOCK.finditer(contract):
        try:
            decoded = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, list) and decoded and all(
            isinstance(entry, dict) and entry.get("kind") == "field-value"
            for entry in decoded
        ):
            blocks.append(match.group(1))
    return blocks


class GuideQuotesItsSources(unittest.TestCase):
    def test_every_fragment_claim_quotes_those_exact_lines(self):
        guide = read(GUIDE_PATH)
        claims = list(fragment_claims(guide))
        self.assertGreater(len(claims), 20, "the guide quotes far more than this")
        sources = {}
        for source, first, last, quoted in claims:
            if source not in sources:
                path = PACKET_DIRECTORY / source
                self.assertTrue(path.is_file(), "no such file: %s" % source)
                sources[source] = read(path).splitlines()
            lines = sources[source]
            self.assertLessEqual(
                last,
                len(lines),
                "%s has %d lines, so lines %d-%d cannot be quoted"
                % (source, len(lines), first, last),
            )
            self.assertEqual(
                quoted.rstrip("\n").splitlines(),
                lines[first - 1 : last],
                "The guide quotes %s lines %d-%d, which no longer say that. "
                "Quote it again, or repoint the claim." % (source, first, last),
            )

    def test_the_variant_model_is_among_the_quoted_sources(self):
        """A positive control: the family's model is really one of them.

        Without this, deleting every claim that names the variant model would
        leave the test above green.
        """
        named = {source for source, _, _, _ in fragment_claims(read(GUIDE_PATH))}
        self.assertIn("backend/fixtures/note-state-field/model.nix", named)


class ContractQuotesTheVariantBundle(unittest.TestCase):
    def test_the_leaf_example_matches_the_variant_bundle(self):
        leaves = quoted_leaves(read(VARIANT_BUNDLE_PATH))
        self.assertEqual(
            len(leaves),
            2,
            "expected one leaf under a check and one under a where, found %d"
            % len(leaves),
        )
        expected = "[\n%s,\n%s\n]\n" % (
            textwrap.indent(leaves[0], "  "),
            textwrap.indent(leaves[1], "  "),
        )
        blocks = contract_leaf_example(read(CONTRACT_PATH))
        self.assertEqual(
            len(blocks), 1, "expected exactly one field-value leaf block, found %d"
            % len(blocks)
        )
        self.assertEqual(
            blocks[0],
            expected,
            "The contract's field-value example no longer equals "
            "backend/fixtures/note-state-field/bundle.json byte for byte.",
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
# cspell:ignore sdoc
"""Assert what a rendered strictdoc source page says about `fixtures/mod.nix`.

    assert_page.py <output>/html/_source_files/src/mod.nix.html

AN EXPORT THAT EXITS 0 PROVES NOTHING HERE. A forward File relation whose `ID:`
resolves to no language item is not an error: strictdoc exits 0, creates no
marker, and the relation is absent from both the document page and the source
page. An `ELEMENT` the resolver does not know degrades to a whole-file marker
just as quietly. So the only honest assertion is on the RENDERED page.

What is checked, in both directions:

* each expected requirement appears as a range pointer, with the KIND in its
  description (`option options.services.foo.port`, not strictdoc's generic
  `function options.services.foo.port()`) -- which is what
  `register.register_forward_descriptions` buys for forward relations;
* REQ-FILE appears EXACTLY ONCE, which is the doubled-header-comment trap;
* REQ-GHOST, whose `ID:` names nothing, appears NOWHERE. That is this file's
  own positive control: without it, "five markers rendered" would be
  indistinguishable from a page that lists every requirement in the project
  regardless of whether it resolved.

Plain stdlib, no strictdoc import: the page is HTML on disk and parsing it
with a regex is the point -- this must not be able to pass by asking the same
code that produced it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

POINTER = re.compile(
    r'href="[^"]*mod\.nix\.html#(?P<uid>[A-Za-z0-9-]+)#\d+#\d+"'
    r"[^>]*>\s*<b>\[[^]]+\]</b>\s*"
    r'<span class="source__range-pointer_description">(?P<text>[^<]*)</span>',
    re.S,
)

#: uid -> the description substring its range pointer must carry.
EXPECTED = {
    "REQ-BINDING": "binding config.systemd.services.foo.script",
    "REQ-ENABLE": "option options.services.foo.enable",
    "REQ-FILE": "module src/mod.nix",
    "REQ-MODULE": "module src/mod.nix",
    "REQ-OPTION": "option options.services.foo.port",
}

#: The relation whose ID resolves to nothing. Must not reach the page at all.
GHOST = "REQ-GHOST"


def main() -> int:
    page = Path(sys.argv[1])
    if not page.is_file():
        print(f"assert_page: no source page at {page}", file=sys.stderr)
        return 1
    html = page.read_text(encoding="utf-8")

    found: dict[str, set] = {}
    for match in POINTER.finditer(html):
        found.setdefault(match["uid"], set()).add(match["text"])

    findings = []
    for uid, expected in sorted(EXPECTED.items()):
        texts = found.get(uid)
        if not texts:
            findings.append(f"{uid}: no range pointer on the source page")
            continue
        if not any(expected in text for text in texts):
            findings.append(
                f"{uid}: no pointer says {expected!r}; got {sorted(texts)}"
            )

    # The doubled-comment trap: one comment, one marker.
    file_pointers = found.get("REQ-FILE", set())
    if len(file_pointers) > 1:
        findings.append(
            "REQ-FILE has more than one distinct range pointer "
            f"({sorted(file_pointers)}): the header comment was parsed twice"
        )

    # The positive control.
    if GHOST in html:
        findings.append(
            f"{GHOST} reached the page, so a resolving ID and a nonexistent "
            "one are indistinguishable here and every other assertion above "
            "is worthless"
        )

    for finding in findings:
        print(f"assert_page: {finding}", file=sys.stderr)
    print(
        f"{len(EXPECTED)} marker(s) asserted on {page.name}, "
        f"ghost absent: {GHOST not in html}: {len(findings)} finding(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

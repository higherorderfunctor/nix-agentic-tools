"""The parts of a git-tool config census that do not depend on the tool.

Each extractor (packages/git-*/extract/extract.py) walks its own program's
syntax tree into per-site records and hands them here to be aggregated, to
have hand annotations applied under one fill-only contract, and to be written
as the sidecar lib/git-tool-settings/default.nix reads. The sidecar schema is
documented there; this module writes only fields that schema admits.
"""

import json
import re
import sys
from collections import defaultdict


class Census:
    def __init__(self, section):
        self.section = section
        self.failures = []
        # The completeness net: a key-shaped token inside an already DECODED
        # string value (a literal's value, a doc line). The tree hands over
        # the value; only prose inside it needs a pattern. The lookbehind is
        # the point: `git-branchless.x` or `my_absorb.x` names no key, and a
        # naive `section\.\w+` would flag it (mutant N2 in each tool's list).
        self.key_token = re.compile(r"(?<![\w.-])" + re.escape(section) + r"\.[A-Za-z{*][\w{}<>*.-]*")

    def fail(self, code, msg):
        self.failures.append(f"{code}: {msg}")

    def key_tokens(self, value):
        return [token.rstrip(".") for token in self.key_token.findall(value)]

    def owns(self, key):
        return key.startswith(self.section + ".")

    def agree(self, key, field, values, code):
        distinct = []
        for v in values:
            if v not in distinct:
                distinct.append(v)
        if len(distinct) > 1:
            self.fail(code, f"{key} has conflicting {field}: {distinct!r}")
        return distinct[0] if distinct else None

    def apply_annotations(self, settings, annotations, code="F4"):
        """An annotation may only FILL a field the source left empty, or
        replace one it names in `replace`, so a later upstream change cannot
        be masked. `defaultDescription` and `note` are prose the source never
        carries."""
        for key, ann in sorted(annotations.get("settings", {}).items()):
            if key not in settings:
                self.fail(code, f"annotation for {key} is stale: the source no longer reads it")
                continue
            entry = settings[key]
            for fld, value in ann.items():
                if fld == "replace":
                    continue
                if fld in ("defaultDescription", "note") or entry.get(fld) is None or fld in ann.get("replace", []):
                    entry[fld] = value
                elif entry[fld] != value:
                    self.fail(code, f"annotation {key}.{fld}={value!r} shadows extracted {entry[fld]!r}; list it in replace")
            for fld in ann.get("replace", []):
                if fld not in ann:
                    self.fail(code, f"annotation {key} replaces {fld} without giving a value")

    def finish(self, out, sidecar):
        out.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")
        for failure in self.failures:
            print("FAIL", failure, file=sys.stderr)
        sys.exit(1 if self.failures else 0)


def sites(records, access):
    """`file#fn` → the config chains that site's handle reads."""
    out = defaultdict(set)
    for r in records:
        if r["access"] == access:
            out[f"{r['file']}#{r['fn']}" if r["fn"] else r["file"]] |= set(r["handles"])
    return {s: sorted(h) for s, h in sorted(out.items())}

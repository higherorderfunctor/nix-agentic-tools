#!/usr/bin/env python3
"""Render the shared rule families; --check proves each case is byte-identical.

Identical cases link to their base. The h2 and inline variants are committed generated
files so all documented cases/<id>/rules.json paths resolve in a fresh checkout.
Run without --check to regenerate after editing a base or a case delta.
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FAMILIES = {
    "a2": ("a2-cancelchild", "a2-steerchild", "j-a2-cancel-cfg"),
    "h2": ("h2-agentpin", "h2-all", "h2-effort", "h2-hookblock", "h2-trustdel"),
    "h3": ("h3-all", "h3-hookblock", "h3-perm", "h3-trustdel2"),
    "inline": ("v3-inline", "v3-inline-ignored"),
}
STAGE = '''              "name": "st0",
              "role": "custom",
              "prompt_template": "CHILD_PERM {task}",
              "model": "claude-haiku-4.5"'''
SECOND_STAGE = ''',
            {
              "name": "st1",
              "role": "custom",
              "prompt_template": "CHILD_PERM2 {task}"
            }'''
SECOND_RULE = '''  {
    "match": ["orchestrated session", "CHILD_PERM2"],
    "events": ["CHILD2_DONE"]
  },
'''


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one delta anchor: {old!r}")
    return text.replace(old, new, 1)


def render(family, case):
    text = (HERE / "rules" / f"{family}.json").read_text()
    if case == "h2-agentpin":
        text = replace_once(text, STAGE, STAGE.replace('"custom"', '"pinned"')
                            .replace(',\n              "model": "claude-haiku-4.5"', ''))
    elif case == "h2-effort":
        text = replace_once(text, STAGE + "\n            }",
                            STAGE + "\n            }" + SECOND_STAGE)
        anchor = '  {\n    "match": "MAIN_KICKOFF",'
        # Insert before the final parent reply, not its first tool call.
        offset = text.rindex(anchor)
        text = text[:offset] + SECOND_RULE + text[offset:]
    elif case == "v3-inline-ignored":
        text = replace_once(text, '\"inlineAgents\": {\n      \"enabled\": true\n    }',
                            '\"inlineAgents\": \"on\"')
    return text


def case_path(family, case):
    if family == "inline":
        return HERE / "codex-side" / "cases" / f"{case}.json"
    return HERE / "cases" / case / "rules.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="kiro-rules-") as tmp:
        for family, cases in FAMILIES.items():
            for case in cases:
                target = case_path(family, case)
                output = Path(tmp) / f"{case}.json"
                output.write_text(render(family, case))
                if args.check:
                    result = subprocess.run(["diff", "-u", str(target), str(output)])
                    print(f"{target.relative_to(HERE)} diff exit {result.returncode}", flush=True)
                    if result.returncode:
                        raise SystemExit(result.returncode)
                elif not target.is_symlink():
                    target.write_bytes(output.read_bytes())
                elif target.read_bytes() != output.read_bytes():
                    raise SystemExit(f"{target}: base link no longer matches its delta")


if __name__ == "__main__":
    main()

"""The command line front end.

    python3 -m sdoc_semantics evaluate --bundle BUNDLE --candidate CANDIDATE
        [--invocation INVOCATION] [--out OUT] [--evaluation ID]

Exit codes: 0 when the envelope is satisfied, which is the only state in which
the candidate may be accepted (contract.md:665); 1 when the envelope is
violated, blocked or error, the envelope still being written because those
verdicts are reported inside it; 2 when no envelope can be produced at all,
because the results array must carry exactly one entry per bundle rule
(contract.md:570-573) and an unusable bundle leaves no rule set to enumerate.
"""

import argparse
import json
import sys

from . import engine
from . import loading


def main(argv=None):
    parsed = _parser().parse_args(argv)
    try:
        envelope = engine.evaluate_bundle(
            parsed.bundle, parsed.candidate, parsed.invocation, parsed.evaluation
        )
    except (loading.ConfigurationError, OSError, ValueError) as problem:
        sys.stderr.write("sdoc_semantics: %s\n" % problem)
        return 2
    text = json.dumps(envelope, indent=2, ensure_ascii=False) + "\n"
    if parsed.out:
        with open(parsed.out, "w", encoding="utf-8") as stream:
            stream.write(text)
    else:
        sys.stdout.write(text)
    return 0 if envelope["status"] == "satisfied" else 1


def _parser():
    parser = argparse.ArgumentParser(
        prog="python3 -m sdoc_semantics",
        description="Evaluate a candidate document graph against a bundle.",
    )
    subcommands = parser.add_subparsers(dest="subcommand", required=True)
    evaluate = subcommands.add_parser(
        "evaluate", help="Evaluate one candidate and write one result envelope."
    )
    evaluate.add_argument("--bundle", required=True, help="Path to bundle.json.")
    evaluate.add_argument(
        "--candidate", required=True, help="Path to the complete final candidate.json."
    )
    evaluate.add_argument(
        "--invocation",
        default=None,
        help="Path to invocation.json holding the external input bindings.",
    )
    evaluate.add_argument(
        "--out", default=None, help="Write the envelope here instead of stdout."
    )
    evaluate.add_argument(
        "--evaluation",
        default=None,
        help="The caller's invocation id, which the envelope echoes unchanged.",
    )
    return parser


if __name__ == "__main__":
    sys.exit(main())

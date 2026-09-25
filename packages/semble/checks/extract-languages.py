# Extracts Semble's language knowledge from the pinned package into the shape
# of packages/semble/extracted.json. Run under the pinned package's own
# interpreter and module path (checks/semble-script.nix prepends the
# wrapped entry point's site setup), so every value is read by importing the
# modules Semble itself imports, never by parsing source text.
#
# Every key is emitted sorted, so the output is identical on every system
# whose bundled grammar set matches semble-grammars' sources.json. That match
# is asserted here: semble-grammars ships one wheel per platform, each with
# its own manifest, and sources.json is the platform-independent build list.
# A platform that dropped a grammar would otherwise produce a silently
# different file, so it fails instead.
import json
import sys
from importlib import resources
from importlib.metadata import version

import semble_grammars
from semble.index import files
from semble_grammars import loader

bundled = sorted(semble_grammars.available_languages())
sources = sorted(json.loads((resources.files("semble_grammars") / "grammars" / "sources.json").read_text()))
if bundled != sources:
    missing = sorted(set(sources) - set(bundled))
    extra = sorted(set(bundled) - set(sources))
    sys.exit(
        f"FAIL: this platform's grammar manifest differs from sources.json (missing {missing}, extra {extra}); "
        "extracted.json can no longer be platform-independent"
    )

json.dump(
    {
        "contentTypes": {
            content_type.value: sorted(languages) for content_type, languages in files._CONTENT_TYPE_LANGUAGES.items()
        },
        "dataLanguages": sorted(files._DATA_LANGUAGES),
        "extensions": dict(sorted(files._EXTENSION_TO_LANGUAGE.items())),
        "grammars": {
            "aliases": dict(sorted(loader._ALIASES.items())),
            "bundled": bundled,
        },
        "provenance": {
            "extractorSchema": 1,
            "sembleGrammarsVersion": version("semble-grammars"),
            "sembleVersion": version("semble"),
        },
    },
    sys.stdout,
    indent=2,
    sort_keys=True,
)
sys.stdout.write("\n")

"""The retained fixture is a separate StrictDoc project."""

from strictdoc.api import ProjectConfig
from strictdoc.backend.json.json_format import JSONFormat
from strictdoc.backend.sdoc.sdoc_format import SDocFormat


def create_config() -> ProjectConfig:
    return ProjectConfig(
        dir_for_sdoc_cache="$TMPDIR",
        formats=[SDocFormat(), JSONFormat()],
        grammars={"@repo": "grammar.sgra"},
        include_doc_paths=["documents/**", "grammar.sgra"],
        project_title="StrictDoc semantic library fixture",
    )

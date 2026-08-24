"""StrictDoc project configuration for nix-agentic-tools.

The project root is the repository root so that plan documents under
docs/plans/, settled architecture under **/.sdoc/, and any future
source-extracted nodes all land in ONE graph and can cite each other.

Two things make that work and both are load-bearing:

* grammars: IMPORT_FROM_FILE accepts only a bare filename resolved next to the
  document, so a nested layout would need a copy of grammar.sgra in every
  directory. Registering an alias here means every document, at any depth,
  writes `IMPORT_FROM_FILE: @repo`.

* exclude_doc_paths: StrictDoc ingests every .md file in the input tree as a
  document. Unfiltered, an export aborts on the first markdown file with no H1
  or with a second H1. BOTH globs are required -- "**/*.md" alone still
  ingests root-level AGENTS.md, README.md and CONTRIBUTING.md.
"""

from strictdoc.api import ProjectConfig


def create_config() -> ProjectConfig:
    return ProjectConfig(
        project_title="nix-agentic-tools design graph",
        grammars={"@repo": "docs/sdoc/grammar.sgra"},
        exclude_doc_paths=["*.md", "**/*.md"],
    )

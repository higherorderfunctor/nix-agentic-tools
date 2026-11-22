"""Print the bundled core version for the updater after checking Pydantic's exact requirement."""

import sys
import tomllib
from pathlib import Path

from packaging.requirements import Requirement

source = Path(sys.argv[1])
with (source / "pydantic-core/Cargo.toml").open("rb") as cargo:
    core_version = tomllib.load(cargo)["package"]["version"]
with (source / "pyproject.toml").open("rb") as project:
    requirements = tomllib.load(project)["project"]["dependencies"]

if Requirement(f"pydantic-core=={core_version}") not in map(Requirement, requirements):
    sys.exit(f"Pydantic must require the bundled pydantic-core=={core_version}")
print(core_version)

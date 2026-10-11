"""Select a dependency release allowed by the currently pinned Semble release."""

import json
import sys
from pathlib import Path
from urllib.request import urlopen

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


def pypi(project):
    with urlopen(f"https://pypi.org/pypi/{project}/json") as response:
        return json.load(response)


def main():
    sources_file, dependency = sys.argv[1:]
    version = json.loads(Path(sources_file).read_text())["version"]
    requirements = [
        Requirement(entry)
        for entry in pypi(f"semble/{version}")["info"]["requires_dist"] or []
    ]
    requirement = next(
        (
            requirement
            for requirement in requirements
            if canonicalize_name(requirement.name) == canonicalize_name(dependency)
            and (
                requirement.marker is None
                or requirement.marker.evaluate({"extra": ""})
            )
        ),
        None,
    )
    if requirement is None:
        sys.exit(f"Semble {version} has no non-extra requirement for {dependency}")
    releases = pypi(dependency)["releases"]
    compatible = list(requirement.specifier.filter(releases, prereleases=False))
    if not compatible:
        sys.exit(f"No stable PyPI release of {dependency} satisfies {requirement}")
    print(max(compatible, key=Version))


if __name__ == "__main__":
    main()

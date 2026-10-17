"""Select the newest stable dependency release allowed by pinned parents."""

import argparse
import json
import sys
import tomllib
from pathlib import Path
from urllib.request import urlopen

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


def pypi(project):
    with urlopen(f"https://pypi.org/pypi/{project}/json") as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dependency")
    parser.add_argument("--runtime", nargs=2, action="append", default=[], metavar=("PROJECT", "PIN"))
    parser.add_argument("--build-system", nargs=2, action="append", default=[], metavar=("URL", "PIN"))
    args = parser.parse_args()
    parents = []
    for project, pin in args.runtime:
        version = json.loads(Path(pin).read_text())["version"]
        parents.append((f"{project} {version}", pypi(f"{project}/{version}")["info"]["requires_dist"] or []))
    for url, pin in args.build_system:
        version = json.loads(Path(pin).read_text())["version"]
        with urlopen(url.format(version=version)) as response:
            metadata = tomllib.loads(response.read().decode())
        parents.append((url.format(version=version), metadata["build-system"]["requires"]))
    if not parents:
        parser.error("at least one pinned parent is required")

    requirements = []
    for parent, entries in parents:
        matching = [
            requirement
            for entry in entries
            if canonicalize_name((requirement := Requirement(entry)).name) == canonicalize_name(args.dependency)
            and (requirement.marker is None or requirement.marker.evaluate({"extra": ""}))
        ]
        if not matching:
            sys.exit(f"{parent} has no non-extra requirement for {args.dependency}")
        requirements.extend(matching)

    releases = pypi(args.dependency)["releases"]
    compatible = releases.keys()
    for requirement in requirements:
        compatible = list(requirement.specifier.filter(compatible, prereleases=False))
    if not compatible:
        sys.exit(f"No stable PyPI release of {args.dependency} satisfies {requirements}")
    print(max(compatible, key=Version))


if __name__ == "__main__":
    main()

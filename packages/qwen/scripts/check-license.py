"""Reject model revisions whose embedded licence no longer matches our notice."""

import sys

from gguf import GGUFReader


def check_license(path):
    field = GGUFReader(path).get_field("general.license")
    license_id = field.contents() if field is not None else None
    if license_id != "apache-2.0":
        raise ValueError(f"Expected general.license apache-2.0, got {license_id!r}")


if __name__ == "__main__":
    check_license(sys.argv[1])

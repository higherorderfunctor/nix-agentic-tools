"""Accept archived bytes for the files traversed by the location golden rows."""

from pathlib import Path
import sys


archive, fixture = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
expectations = [Path(path) for path in sys.argv[3:]] or [fixture / "Locations.expected"]
files = sorted({line.split("|")[1].strip()
                for golden in expectations for line in golden.read_text().splitlines()})
for name in files:
    entry = archive / (fixture / name).as_posix().lstrip("/")
    if not entry.is_file():
        sys.exit(f"missing archived fixture: {name}")
    if entry.read_bytes() != (fixture / f"{name}.in").read_bytes():
        sys.exit(f"corrupt archived fixture: {name}")
print(f"source archive accepted: {len(files)} fixture entries with exact bytes")

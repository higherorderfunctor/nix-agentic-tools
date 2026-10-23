"""Assemble exact kit/F1 bytes and inventory the pinned generated declarations."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def declarations(text, pattern):
    # Neither the kit nor CodeQL exposes a declaration inventory API. These
    # generated QL/dbscheme formats have no supported standalone parser; inspect
    # their declarations after removing comments, never string-valued source.
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    names = re.findall(pattern, text, flags=re.M)
    if not names:
        raise ValueError("empty generated declaration inventory")
    return sorted(set(names))


def main():
    raw, handwritten, pins, destination = sys.argv[1:]
    root = Path(destination)
    ast = root / "nix/internal/generated/Ast.qll"
    ast.parent.mkdir(parents=True, exist_ok=True)
    schema = root / "nix.dbscheme"
    subprocess.run([raw, str(schema), str(ast)], check=True)
    combined = schema.read_bytes() + b"\n" + Path(handwritten).read_bytes()
    schema.write_bytes(combined)
    manifest = {
        "classes": declarations(ast.read_text(), r"\bclass\s+(\w+)\s+(?:extends|=)"),
        "pins": json.loads(Path(pins).read_text()),
        "schemaSha256": hashlib.sha256(combined).hexdigest(),
        "tables": declarations(combined.decode(), r"^(\w+)\s*\("),
    }
    (root / "schema-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )


if __name__ == "__main__":
    main()

"""Print the Rust channel declared at the recipe's crate/workspace root."""

import sys
import tomllib
from pathlib import Path


def channel_of(root: Path) -> str:
    if not root.is_dir():
        raise ValueError(f"{root}: Rust crate/workspace root is not a directory")
    files = [root / name for name in ("rust-toolchain", "rust-toolchain.toml")]
    present = [path for path in files if path.is_file()]
    if not present:
        return ""
    if len(present) != 1:
        raise ValueError(f"{root}: both rust-toolchain and rust-toolchain.toml exist")
    path = present[0]
    text = path.read_text().strip()
    # rustup accepts the legacy file as a bare channel or as TOML.
    if path.suffix == ".toml" or len(text.splitlines()) != 1 or text.startswith(("[", "#")):
        channel = tomllib.loads(text).get("toolchain", {}).get("channel")
    else:
        channel = text
    if not isinstance(channel, str) or not channel or len(channel.splitlines()) != 1:
        raise ValueError(f"{path}: expected one nonempty toolchain channel")
    return channel


if __name__ == "__main__":
    try:
        print(channel_of(Path(sys.argv[1])))
    except (OSError, ValueError) as error:
        sys.exit(f"rust-toolchain: {error}")

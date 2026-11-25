# pyright: strict
# cspell:ignore keepends
"""Apply each named single-line fault on the writable review copy, then run the same pytest suite."""

import os
from pathlib import Path
import subprocess
import sys

from pydantic import BaseModel, ConfigDict


class Fault(BaseModel):
    """One TSV row names its behaviors and the complete source line it replaces."""

    model_config = ConfigDict(extra="forbid", strict=True)
    module: str
    behaviors: str
    original: str
    replacement: str


def main(table: Path, output: Path) -> None:
    """Keep survivors for review and stop if a fault cannot be applied or pytest cannot run."""
    matrix = Path(os.environ["MATRIX_FILE"])
    with table.open() as stream, output.open("w") as results, matrix.open() as outcomes:
        next(stream)
        outcomes.seek(0, os.SEEK_END)
        for number, row in enumerate(stream, 1):
            module, behaviors, original, replacement = row.rstrip("\n").split("\t")
            fault = Fault(module=module, behaviors=behaviors, original=original, replacement=replacement)
            path = Path(fault.module)
            source = path.read_text()
            lines = source.splitlines(keepends=True)
            old = fault.original + "\n"
            if lines.count(old) != 1:
                raise ValueError(f"{table}:{number + 1}: expected one matching line in {path}")
            lines[lines.index(old)] = fault.replacement + "\n"
            name = f"named-{number}"
            try:
                path.write_text("".join(lines))
                process = subprocess.run(
                    [sys.executable, "-B", "-m", "pytest", "-q", "--tb=no"],
                    env=os.environ | {"NAMED_FAULT": name}, capture_output=True, text=True,
                )
            finally:
                path.write_text(source)
            phases = [tuple(line.rstrip("\n").split("\t")[-2:]) for line in outcomes.readlines()]
            failed = {phase for phase, outcome in phases if outcome == "failed"}
            if process.returncode == 1 and failed == {"call"}:
                status = "killed"
            elif process.returncode == 0 and not failed and ("call", "passed") in phases:
                status = "survived"
            else:
                status = f"invalid (pytest exit {process.returncode}, failed phases {','.join(sorted(failed)) or 'none'})"
            print(name, status, fault.behaviors, sep="\t", file=results)


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))

"""Mapped discovery and languages agree between serial and spawned indexing."""

import os
from pathlib import Path

import numpy as np

from semble.index.create import create_index_from_path
from semble.types import ContentType


class FixedModel:
    dim = 8

    def encode(self, texts, **_kwargs):
        return np.ones((len(texts), self.dim), dtype=np.float32)


def main() -> None:
    root = Path("worker-repo").resolve()
    for directory in ("scripts", "docs"):
        (root / directory).mkdir(parents=True)
    for number in range(205):
        (root / "scripts" / f"job-{number:03}").write_text(
            f"#!/bin/bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\necho gamma worker {number}\n",
            encoding="utf-8",
        )
        (root / "docs" / f"note-{number:03}.py").write_text(
            f"These gamma notes use line chunking {number}\n", encoding="utf-8"
        )
    (root / "main.py").write_text("def gamma():\n    return 1\n", encoding="utf-8")

    for content, directory, language in (
        (ContentType.CODE, "scripts", "bash"),
        (ContentType.DOCS, "docs", None),
    ):
        indexes = []
        for workers in (0, 2):
            os.environ["SEMBLE_INDEX_WORKERS"] = str(workers)
            _, _, chunks, _ = create_index_from_path(
                root, FixedModel(), content=content, display_root=root.parent
            )
            by_file = {}
            for chunk in chunks:
                by_file.setdefault(chunk.file_path, []).append(chunk)
            expected = {f"{root.name}/{directory}/{p.name}" for p in (root / directory).iterdir()}
            if content == ContentType.CODE:
                expected.add(f"{root.name}/main.py")
                assert all(chunk.language == "python" for chunk in by_file[f"{root.name}/main.py"])
            assert set(by_file) == expected, (content, workers, set(by_file) ^ expected)
            for name in expected - {f"{root.name}/main.py"}:
                assert all(chunk.language == language for chunk in by_file[name]), name
            indexes.append(chunks)
        assert indexes[0] == indexes[1], content
        print(f"{content.value}: {len(expected)} files; serial and 2 spawned workers agree")


if __name__ == "__main__":
    main()

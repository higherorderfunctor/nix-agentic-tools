"""Mapped discovery and languages agree between serial and spawned indexing."""

import os
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from unittest.mock import patch

import numpy as np

from semble.index import create
from semble.types import ContentType


class FixedModel:
    dim = 8

    def encode(self, texts, **_kwargs):
        return np.ones((len(texts), self.dim), dtype=np.float32)


def main() -> None:
    root = Path("worker-repo").resolve()
    # Each content set exceeds the 200-file dispatch threshold on its own.
    # The .py docs would ordinarily be code; the scripts have no extension.
    scripts = [f"scripts/job-{number:03}" for number in range(205)]
    docs = [f"docs/note-{number:03}.py" for number in range(205)]
    for names, text in ((scripts, "echo gamma worker"), (docs, "These gamma notes use line chunking")):
        (root / names[0]).parent.mkdir(parents=True)
        for number, name in enumerate(names):
            (root / name).write_text(f"{text} {number}\n", encoding="utf-8")
    (root / "main.py").write_text("def gamma():\n    return 1\n", encoding="utf-8")

    for content, expected in (
        (ContentType.CODE, dict.fromkeys(scripts, "bash") | {"main.py": "python"}),
        (ContentType.DOCS, dict.fromkeys(docs, None)),
    ):
        indexes = []
        for workers in (0, 2):
            submitted = []
            denied = []

            class ObservedPool(ProcessPoolExecutor):
                def __init__(self, *args, **kwargs):
                    assert kwargs["mp_context"].get_start_method() == "spawn"
                    try:
                        super().__init__(*args, **kwargs)
                    except (OSError, NotImplementedError) as exc:
                        denied.append(exc)
                        raise

                def submit(self, fn, *args, **kwargs):
                    future = super().submit(fn, *args, **kwargs)
                    submitted.append(future)
                    return future

            os.environ["SEMBLE_INDEX_WORKERS"] = str(workers)
            with patch.object(create, "ProcessPoolExecutor", ObservedPool):
                _, _, chunks, _ = create.create_index_from_path(
                    root, FixedModel(), content=content, display_root=root.parent
                )
            # Only an observed sandbox denial may excuse falling back to serial on Darwin.
            if denied:
                assert workers == 2 and sys.platform == "darwin", denied
                print(f"{content.value}: sandbox denied the worker pool: {denied[0]}")
            else:
                assert len(submitted) == (len(expected) if workers else 0), (content, workers, len(submitted))

            if workers == 0:
                by_file = {}
                for chunk in chunks:
                    by_file.setdefault(chunk.file_path, set()).add(chunk.language)
                expected_paths = {f"worker-repo/{name}": {language} for name, language in expected.items()}
                mismatched = {
                    name: (expected_paths.get(name), by_file.get(name))
                    for name in expected_paths.keys() | by_file.keys()
                    if by_file.get(name) != expected_paths.get(name)
                }
                assert not mismatched, (content, workers, mismatched)
            indexes.append(chunks)
        # Same members and labels alone would miss output reordered by the worker pool.
        assert indexes[0] == indexes[1], content


if __name__ == "__main__":
    main()

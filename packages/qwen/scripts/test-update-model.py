"""Updater failures must preserve both pins; successful updates replace both."""

import argparse
from contextlib import contextmanager
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("updater", Path(__file__).with_name("update-model.py"))
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    @contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            recipe = Path(directory) / "package.nix"
            original = f'rev = "{"a" * 40}";\nsha256Hex = "{"0" * 64}";\n'
            recipe.write_text(original)
            args = argparse.Namespace(recipe=str(recipe), publisher="Qwen", repo="model",
                                      file="Weights.gguf", revision="selected/tag", nix="nix")
            metadata = {"sha": "b" * 40, "siblings": [
                {"rfilename": args.file, "lfs": {"sha256": "1" * 64}}]}
            yield args, metadata, recipe, original

    def test_success_and_no_change(self):
        with self.fixture() as (args, metadata, recipe, original):
            with patch.object(updater, "urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())) as request:
                with patch.object(updater.subprocess, "run") as prefetch:
                    updater.update(args)
            self.assertIn("selected%2F" + "tag", request.call_args.args[0])
            command = prefetch.call_args.args[0]
            self.assertIn("--expected-hash", command)
            self.assertIn("weights.gguf", command)
            self.assertIn("/resolve/" + "b" * 40 + "/Weights.gguf", command[-1])
            expected = original.replace("a" * 40, "b" * 40).replace("0" * 64, "1" * 64)
            self.assertEqual(recipe.read_text(), expected)
            before = recipe.stat().st_mtime_ns
            with patch.object(updater, "urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())):
                with patch.object(updater.subprocess, "run") as prefetch:
                    updater.update(args)
                    prefetch.assert_not_called()
            self.assertEqual(recipe.stat().st_mtime_ns, before)

    def test_fetch_failure_preserves_recipe(self):
        with self.fixture() as (args, metadata, recipe, original):
            with patch.object(updater, "urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())):
                with patch.object(updater.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "nix")):
                    with self.assertRaises(subprocess.CalledProcessError):
                        updater.update(args)
            self.assertEqual(recipe.read_text(), original)

    def test_invalid_metadata_preserves_recipe(self):
        for field in ("revision", "digest", "missing", "non-lfs", "missing-digest"):
            with self.fixture() as (args, metadata, recipe, original):
                if field == "revision":
                    metadata["sha"] = "main"
                elif field == "digest":
                    metadata["siblings"][0]["lfs"]["sha256"] = "invalid"
                elif field == "non-lfs":
                    del metadata["siblings"][0]["lfs"]
                elif field == "missing-digest":
                    metadata["siblings"][0]["lfs"] = {}
                else:
                    metadata["siblings"] = []
                with patch.object(updater, "urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())):
                    with self.assertRaises(ValueError):
                        updater.update(args)
                self.assertEqual(recipe.read_text(), original)

    def test_ambiguous_recipe_fails_before_network(self):
        with self.fixture() as (args, metadata, recipe, original):
            recipe.write_text(original + original)
            with patch.object(updater, "urlopen") as request:
                with self.assertRaises(ValueError):
                    updater.update(args)
                request.assert_not_called()
            self.assertEqual(recipe.read_text(), original + original)


if __name__ == "__main__":
    unittest.main()

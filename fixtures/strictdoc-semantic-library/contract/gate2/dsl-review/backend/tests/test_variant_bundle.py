"""A family's checked-in bundle must still equal the lowering of its model.

A fixture family that authors its own model ships ``model.nix`` beside the
``bundle.json`` every fixture under it is evaluated against. Nothing else in the
suite reads the model, so without this test an edit to the authoring source
would leave the bundle behind and the whole family would keep passing against a
stale lowering.

The comparison is between decoded values, not text: object member order and
insignificant whitespace do not affect comparison (contract.md:633-634), so the
checked-in file may be pretty-printed however the packet bundle is. The failure
message carries the regeneration command, which is the only place that command
is written down.
"""

import json
import pathlib
import shutil
import subprocess
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
FIXTURES_DIRECTORY = BACKEND_DIRECTORY / "fixtures"

# Lowering one model evaluates the stub, the native grammar dsl it imports and
# every keyword check over the result, so the timeout is generous rather than
# tight; a hung evaluation should still fail the run rather than hang it.
LOWERING_TIMEOUT_SECONDS = 300


def read_json(path):
    """Decode one JSON file."""
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


class VariantBundleFreshness(unittest.TestCase):
    """Compares each authored model with the bundle checked in beside it."""

    @unittest.skipUnless(
        shutil.which("nix-instantiate"),
        "nix-instantiate is not on PATH, so no lowering can be produced",
    )
    def test_each_variant_bundle_equals_its_lowering(self):
        models = sorted(FIXTURES_DIRECTORY.rglob("model.nix"))
        self.assertTrue(
            models,
            f"No fixture family under {FIXTURES_DIRECTORY} authors a model.nix.",
        )
        for model_path in models:
            family = model_path.relative_to(FIXTURES_DIRECTORY).parent
            with self.subTest(family=str(family)):
                completed = subprocess.run(
                    [
                        "nix-instantiate",
                        "--eval",
                        "--strict",
                        "--json",
                        str(model_path),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=LOWERING_TIMEOUT_SECONDS,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    f"{family}/model.nix does not evaluate.\n{completed.stderr}",
                )
                bundle_path = model_path.parent / "bundle.json"
                self.assertEqual(
                    read_json(bundle_path),
                    json.loads(completed.stdout),
                    f"{family}/bundle.json is not the lowering of its model. "
                    "Regenerate it: nix-instantiate --eval --strict --json "
                    f"{model_path} | python3 -m json.tool --indent 2 --sort-keys "
                    f"> {bundle_path} && treefmt {bundle_path}",
                )


if __name__ == "__main__":
    unittest.main()

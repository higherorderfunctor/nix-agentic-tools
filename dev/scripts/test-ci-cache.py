#!/usr/bin/env python3
"""Check Hestia pins without Nix or GHA."""

import importlib.util
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location("update_ci_hestia", ROOT / "dev/scripts/update-ci-hestia.py")
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class HestiaPinTest(unittest.TestCase):
    def test_action_and_matrix_use_packaged_release(self):
        package = (ROOT / "dev/ci-hestia.nix").read_text()
        rev = re.search(r'rev = "([0-9a-f]{40})";', package).group(1)
        version = re.search(r'version = "([^"]+)";', package).group(1)
        pins = []
        for path in (ROOT / ".github/actions/check-cache/action.yml",
                     ROOT / ".github/workflows/ci.yml"):
            pins.extend(re.findall(r"uses: Mic92/hestia(?:/matrix)?@([0-9a-f]{40}) # v([^\s]+)",
                                   path.read_text()))
        self.assertEqual(pins, [(rev, version), (rev, version)])

    def test_coordinated_update_rewrites_every_pin(self):
        files = {path: (ROOT / path).read_text() for path in (updater.RECIPE, *updater.ACTIONS)}
        revision = "a" * 40
        updated = updater.updated_files(files, "3.2.0", revision, "sha256-new")
        self.assertIn(f'rev = "{revision}";', updated[updater.RECIPE])
        self.assertIn('version = "3.2.0";', updated[updater.RECIPE])
        self.assertIn('hash = "sha256-new";', updated[updater.RECIPE])
        for path in updater.ACTIONS:
            self.assertIn(f"@{revision} # v3.2.0", updated[path])

    def test_update_runs_rust_toolchain_fixer_after_rewriting_recipe(self):
        revision = "a" * 40
        fixer = "/nix/store/hestia-fix-rust-toolchain"
        build = ("nix", "build", "--no-link", "--print-out-paths",
                 ".#ciPackages.x86_64-linux.ci-hestia.fixRustToolchain")
        commands = [
            (("gh", "api", "repos/Mic92/hestia/releases/latest", "--jq", ".tag_name"), "v3.2.0\n"),
            (("git", "ls-remote", "https://github.com/Mic92/hestia.git", "refs/tags/v3.2.0", "refs/tags/v3.2.0^{}"),
             f"{revision}\trefs/tags/v3.2.0\n"),
            (("prefetch", "--unpack", f"https://github.com/Mic92/hestia/archive/{revision}.tar.gz"), "base32-hash\n"),
            (("nix", "hash", "to-sri", "--type", "sha256", "base32-hash"), "sha256-new\n"),
            (build, f"{fixer}\n"),
            ([fixer], ""),
        ]
        responses = iter(commands)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in (updater.RECIPE, *updater.ACTIONS):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text((ROOT / path).read_text())

            def run(argv, **kwargs):
                expected, stdout = next(responses)
                self.assertEqual(argv, expected)
                if argv == build:
                    recipe = (root / updater.RECIPE).read_text()
                    self.assertIn(f'rev = "{revision}";', recipe)
                    self.assertIn('version = "3.2.0";', recipe)
                    self.assertIn('hash = "sha256-new";', recipe)
                    for path in updater.ACTIONS:
                        self.assertIn(f"@{revision} # v3.2.0", (root / path).read_text())
                return subprocess.CompletedProcess(argv, 0, stdout, "")

            with mock.patch.object(updater, "ROOT", root), \
                 mock.patch.object(updater.sys, "argv", ["update-ci-hestia.py", "gh", "git", "prefetch", "nix"]), \
                 mock.patch.object(updater.subprocess, "run", side_effect=run) as subprocess_run:
                updater.main()
            self.assertEqual(subprocess_run.call_args_list, [
                *(mock.call(argv, check=True, capture_output=True, text=True) for argv, _ in commands[:-1]),
                mock.call([fixer], check=True),
            ])


if __name__ == "__main__":
    unittest.main()

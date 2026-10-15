#!/usr/bin/env python3
"""Check Hestia pins and evaluation-input retention without Nix or GHA."""

import importlib.util
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class HestiaPinTest(unittest.TestCase):
    def test_action_and_matrix_use_packaged_release(self):
        root = Path(__file__).parents[2]
        package = (root / "dev/ci-hestia.nix").read_text()
        rev = re.search(r'rev = "([0-9a-f]{40})";', package).group(1)
        version = re.search(r'version = "([^"]+)";', package).group(1)
        pins = []
        for path in (root / ".github/actions/check-cache/action.yml",
                     root / ".github/workflows/ci.yml"):
            pins.extend(re.findall(r"uses: Mic92/hestia(?:/matrix)?@([0-9a-f]{40}) # v([^\s]+)",
                                   path.read_text()))
        self.assertEqual(pins, [(rev, version), (rev, version)])

    def test_coordinated_update_rewrites_every_pin(self):
        root = Path(__file__).parents[2]
        script = root / "dev/scripts/update-ci-hestia.py"
        spec = importlib.util.spec_from_file_location("update_ci_hestia", script)
        updater = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(updater)
        files = {path: (root / path).read_text() for path in (updater.RECIPE, *updater.ACTIONS)}
        revision = "a" * 40
        updated = updater.updated_files(files, "3.2.0", revision, "sha256-new")
        self.assertIn(f'rev = "{revision}";', updated[updater.RECIPE])
        self.assertIn('version = "3.2.0";', updated[updater.RECIPE])
        self.assertIn('hash = "sha256-new";', updated[updater.RECIPE])
        for path in updater.ACTIONS:
            self.assertIn(f"@{revision} # v3.2.0", updated[path])


class EvaluationInputRetentionTest(unittest.TestCase):
    def test_exact_available_entry_after_registration_and_drain(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Retain original patched evaluation input\n", 1)[1]
        body = step.split("        run: |\n", 1)[1].split("\n      - ", 1)[0]
        script = textwrap.dedent(body)
        services = r'''nix() {
  if [ "$1" = eval ]; then
    [ "$2" = --raw ]
    [ "$3" = .#.ciEvaluationInputs.x86_64-linux.devenv-nixpkgs ]
    printf '%s' "$SOURCE"
  elif [ "$1" = path-info ]; then
    printf '%s\n' "$SOURCE"
  else
    return 1
  fi
}
hestia() {
  [ "$2" = --socket ]
  [ "$3" = "$HESTIA_SOCKET" ]
  case "$1" in
    hook) [ "$#" -eq 4 ] && [ "$4" = "$SOURCE" ] ;;
    drain) [ "$#" -eq 3 ] ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$1" >> "$RUNNER_TEMP/calls"
  if [ "$MODE" = "$1-failure" ]; then return 1; fi
}
curl() {
  [ "$4" = "http://$HESTIA_LISTEN/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo" ]
  printf 'narinfo\n' >> "$RUNNER_TEMP/calls"
  case "$MODE" in
    unavailable) return 22 ;;
    empty) return 0 ;;
    foreign) printf 'StorePath: /nix/store/foreign\n' ;;
    *) printf 'StorePath: %s\n' "$SOURCE" ;;
  esac
}
'''
        for mode in ("hook-failure", "drain-failure", "unavailable", "empty", "foreign", "exact"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(
                    ["bash", "-c", services + script],
                    capture_output=True,
                    env=dict(os.environ, MODE=mode, RUNNER_TEMP=directory,
                             HESTIA_BIN="hestia", HESTIA_SOCKET="socket",
                             HESTIA_LISTEN="127.0.0.1:1234",
                             SOURCE="/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-devenv-nixpkgs-patched"),
                )
                self.assertEqual(result.returncode == 0, mode == "exact", result.stderr)
                if mode == "exact":
                    self.assertEqual((Path(directory) / "calls").read_text().splitlines(),
                                     ["hook", "drain", "narinfo"])


if __name__ == "__main__":
    unittest.main()

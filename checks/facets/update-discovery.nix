{
  pkgs,
  self,
  ...
}: let
  coldName = "update-discovery-cold-version";
  python = pkgs.python3.withPackages (ps: [ps.pyyaml]);
  system = pkgs.stdenv.hostPlatform.system;
  fixture = pkgs.writeText "update-discovery-flake.nix" ''
    {
      inputs.nixpkgs.url = "path:${pkgs.path}";
      inputs.repository = {url = "path:${../..}"; flake = false;};
      outputs = {nixpkgs, repository, ...}: let
        cold = builtins.derivation {
          name = "${coldName}";
          builder = "/intentionally-unusable-builder";
          system = ${builtins.toJSON system};
        };
        packages = assert !builtins.pathExists cold.outPath;
          builtins.seq (builtins.readFile cold.outPath) {};
      in {
        packages.${system} = packages;
        legacyPackages.${system} = packages;
        updateTargets = (import (repository + "/lib/facets/registry.nix") {
          inherit (nixpkgs) lib;
          root = repository.outPath;
        }).config.update.targets;
      };
    }
  '';
in {
  checks.update-discovery-ifd-free =
    pkgs.runCommandLocal "update-discovery-ifd-free" {
      nativeBuildInputs = [pkgs.nix python];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export NIX_STATE_DIR="$TMPDIR/nix-state"
      export NIX_CONFIG='experimental-features = nix-command flakes'
      export XDG_CACHE_HOME="$TMPDIR/cache"
      export GITHUB_WORKSPACE="$PWD"
      export GITHUB_OUTPUT="$PWD/github-output"
      export REQUESTED_TARGETS=""
      export RUNNER_TEMP="$PWD/runner-temp"
      mkdir -p source runner-temp automation/dev
      ln -s ${../../dev/scripts} automation/dev/scripts
      cp ${fixture} source/flake.nix
      # Read the workflow step rather than duplicating its installable spelling.
      python3 - ${../../.github/workflows/update.yml} <<'PY'
      import pathlib
      import sys
      import yaml

      workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
      steps = workflow["jobs"]["discover"]["steps"]
      step = next(step for step in steps if step.get("id") == "targets")
      pathlib.Path("discover.sh").write_text(step["run"])
      PY
      cd source
      nix flake lock --offline
      # The old installable spelling must fail before it can reach the registry.
      if nix eval --json --offline --option allow-import-from-derivation false \
        .#updateTargets > old.json 2> old.log; then
        echo 'package lookup unexpectedly evaluated a cold IFD namespace' >&2
        exit 1
      fi
      if ! grep -F -- '-${coldName}.drv' old.log | grep -F "allow-import-from-derivation' is disabled"; then
        echo 'old installable did not fail on the cold fixture derivation with IFD disabled' >&2
        cat old.log >&2
        exit 1
      fi
      bash ../discover.sh
      python3 - ${pkgs.writeText "expected-update-targets.json" (builtins.toJSON self.updateTargets)} <<'PY'
      import json
      import os
      import pathlib
      import sys
      from collections import Counter

      targets = json.loads((pathlib.Path(os.environ["RUNNER_TEMP"]) / "targets.json").read_text())
      # The outer flake reads the registry without going through CLI discovery.
      expected_targets = json.loads(pathlib.Path(sys.argv[1]).read_text())
      assert expected_targets and targets == expected_targets, "cold discovery did not export the nonempty registry"

      output = pathlib.Path(os.environ["GITHUB_OUTPUT"]).read_text()
      matrices = [line.removeprefix("matrix=") for line in output.splitlines() if line.startswith("matrix=")]
      assert len(matrices) == 1, f"expected one workflow matrix output, got {len(matrices)}"
      rows = Counter((row["kind"], row["name"]) for row in json.loads(matrices[0])["include"])
      # The fixture has exactly these two inputs and no fixture locks of its own.
      expected_rows = Counter([("input", "nixpkgs"), ("input", "repository")])
      expected_rows.update(("package", name) for name in expected_targets)
      assert rows == expected_rows, f"wrong workers: missing {expected_rows - rows}, unexpected {rows - expected_rows}"
      PY
      mkdir -p "$out"
      cp old.log "$RUNNER_TEMP/targets.json" "$GITHUB_OUTPUT" "$out/"
    '';
}

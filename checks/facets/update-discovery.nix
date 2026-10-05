{
  pkgs,
  self,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  python = pkgs.python3.withPackages (ps: [ps.pyyaml]);
  fixture = pkgs.writeText "update-discovery-flake.nix" ''
    {
      inputs.nixpkgs.url = "path:${pkgs.path}";
      inputs.repository = {url = "path:${../..}"; flake = false;};
      outputs = {nixpkgs, repository, ...}: let
        cold = builtins.derivation {
          name = "update-discovery-cold-version";
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
      grep -F "allow-import-from-derivation' is disabled" old.log
      bash ../discover.sh
      python3 - ${pkgs.writeText "expected-update-targets.json" (builtins.toJSON self.updateTargets)} <<'PY'
      import json
      import os
      import pathlib
      import sys

      targets = json.loads((pathlib.Path(os.environ["RUNNER_TEMP"]) / "targets.json").read_text())
      assert targets == json.loads(pathlib.Path(sys.argv[1]).read_text())
      output = pathlib.Path(os.environ["GITHUB_OUTPUT"]).read_text()
      matrix = json.loads(next(line.removeprefix("matrix=") for line in output.splitlines() if line.startswith("matrix=")))
      assert targets
      lock = json.loads(pathlib.Path("flake.lock").read_text())
      inputs = lock["nodes"][lock["root"]]["inputs"]
      assert {row["name"] for row in matrix["include"]} == set(targets) | set(inputs)
      PY
      mkdir -p "$out"
      cp old.log "$RUNNER_TEMP/targets.json" "$GITHUB_OUTPUT" "$out/"
    '';
}

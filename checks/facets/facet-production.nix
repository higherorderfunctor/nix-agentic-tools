{pkgs, ...}: {
  checks.facet-owner-relocation = let
    system = pkgs.stdenv.hostPlatform.system;
    probe = pkgs.writeText "facet-owner-relocation.nix" ''
      {root, collision ? false, policy ? "allow"}: let
        pkgs = import ${pkgs.path} {system = ${builtins.toJSON system};};
        inherit (pkgs) lib;
        repository = import ${../..}/lib/facets/repository.nix {
          inputs.nixpkgs = {outPath = ${pkgs.path}; inherit lib;};
          registryModules = [];
          root = builtins.toPath root;
        };
        consumerPkgs = import ${pkgs.path} {
          system = ${builtins.toJSON system};
          config = {
            allowUnfree = policy == "allow";
            allowUnfreePredicate = package:
              policy == "predicate" && lib.getName package == "facet-unfree-control";
          };
          overlays = [repository.overlay];
        };
        package = consumerPkgs.ai.gitTools.git-revise;
        checks = repository.checksFor {
          pkgs = consumerPkgs;
          rootModules = lib.optional collision {
            checks.git-revise-package = pkgs.runCommand "root-collision" {} "touch $out";
          };
          self.packages.${system}.git-revise = package;
        };
      in {
        checks = builtins.mapAttrs (_: check: check.drvPath) checks;
        drvPath = package.drvPath;
        file = repository.update.targets.git-revise.file;
        ninjaHasOwner = lib.hasInfix "build update-git-revise: update-pkg" (
          import ${../../config/generate-update-ninja.nix} {
            flakeLock.nodes.root.inputs = {};
            updateTargets = repository.update.targets;
          }
        );
        unfree = lib.optionalAttrs (consumerPkgs.ai ? facet-unfree-control) {
          drvPath = consumerPkgs.ai.facet-unfree-control.drvPath;
        };
      }
    '';
  in
    pkgs.runCommandLocal "facet-owner-relocation" {
      nativeBuildInputs = [pkgs.jq pkgs.nix];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      USER="$(id -un)"
      export USER
      export NIX_STATE_DIR="$TMPDIR/nix-state"
      export NIXPKGS_ALLOW_UNFREE=0
      mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER" repository/packages
      cp -R ${../../packages/git-revise} repository/packages/git-revise
      chmod -R u+w repository
      nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" > before.json
      mv repository/packages/git-revise repository/packages/relocated-owner
      nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" > after.json
      jq -e -s '
        (.[0].checks | length) > 0 and
        .[0].ninjaHasOwner and
        (.[0] | del(.file)) == (.[1] | del(.file)) and
        .[0].file == "packages/git-revise/packages/ai/gitTools/git-revise/package.nix" and
        .[1].file == "packages/relocated-owner/packages/ai/gitTools/git-revise/package.nix"
      ' before.json after.json
      if nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" --arg collision true > collision.json 2> collision.log; then
        echo 'root/owner duplicate check unexpectedly passed' >&2
        exit 1
      fi
      grep -F 'git-revise-package' collision.log
      grep -F '<root>' collision.log
      grep -F 'relocated-owner' collision.log

      mkdir -p repository/packages/unfree-control/packages/ai/facet-unfree-control
      cp ${pkgs.writeText "facet-unfree-control.nix" ''
        {pkgs, ...}: pkgs.runCommand "facet-unfree-control-1" {
          version = "1";
          meta.license = pkgs.lib.licenses.unfree;
        } "touch $out"
      ''} repository/packages/unfree-control/packages/ai/facet-unfree-control/package.nix
      echo '{}' > repository/packages/unfree-control/registry.nix
      for policy in allow predicate; do
        nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" --argstr policy "$policy" > "$policy.json"
        jq -e '.unfree.drvPath | endswith("facet-unfree-control-1.drv")' "$policy.json"
      done
      for policy in deny rejected-predicate; do
        if nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" --argstr policy "$policy" > "$policy.json" 2> "$policy.log"; then
          echo "unfree policy $policy unexpectedly passed" >&2
          exit 1
        fi
        grep -F 'unfree license' "$policy.log"
      done
      mkdir -p "$out"
      cp before.json after.json "$out/"
    '';
}

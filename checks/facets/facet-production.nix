{pkgs, ...}: {
  checks.facet-owner-relocation = let
    system = pkgs.stdenv.hostPlatform.system;
    probe = pkgs.writeText "facet-owner-relocation.nix" ''
      {root, collision ? false, policy ? "deny"}: let
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
          self.ciPackages.${system}.git-revise = package;
        };
      in {
        checks = builtins.mapAttrs (_: check: check.drvPath) checks;
        drvPath = package.drvPath;
        file = repository.update.targets.git-revise.file;
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
      evaluate() {
        nix-instantiate --eval --strict --json ${probe} --argstr root "$PWD/repository" "$@"
      }

      mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER" repository/packages
      cp -R ${../../packages/git-revise} repository/packages/git-revise
      chmod -R u+w repository
      evaluate > before.json
      mv repository/packages/git-revise repository/packages/relocated-owner
      evaluate > after.json
      # The check and derivation must follow the owner, while the update target
      # must change to the new recipe path instead of keeping a stale pointer.
      jq -e -s '
        if (.[0].checks | has("git-revise-package") | not) then
          error("the original owner did not register git-revise-package")
        elif (.[0] | del(.file)) != (.[1] | del(.file)) then
          error("moving the owner changed a check or the package derivation")
        elif .[1].file != "packages/relocated-owner/packages/ai/gitTools/git-revise/package.nix" then
          error("the relocated update target did not follow the owner recipe")
        else true end
      ' before.json after.json
      if evaluate --arg collision true > collision.json 2> collision.log; then
        echo 'root/owner duplicate check unexpectedly passed' >&2
        exit 1
      fi
      grep -F "facet ownership collision in checks at 'git-revise-package'" collision.log
      grep -F '<root> (' collision.log
      grep -F 'relocated-owner (' collision.log | grep -F '/packages/relocated-owner/checks.nix)'

      mkdir -p repository/packages/unfree-control/packages/ai/facet-unfree-control
      cp ${pkgs.writeText "facet-unfree-control.nix" ''
        {pkgs, ...}: pkgs.runCommand "facet-unfree-control-1" {
          version = "1";
          meta.license = pkgs.lib.licenses.unfree;
        } "touch $out"
      ''} repository/packages/unfree-control/packages/ai/facet-unfree-control/package.nix
      echo '{}' > repository/packages/unfree-control/registry.nix
      # The consumer's matching predicate must apply through the overlay, and
      # a consumer that denies unfree must still reject it.
      for row in deny:rejects predicate:admits; do
        policy="''${row%:*}"
        expected="''${row#*:}"
        status=0
        evaluate --argstr policy "$policy" > "$policy.json" 2> "$policy.log" || status=$?
        if [[ "$expected" == admits ]]; then
          if (( status != 0 )) || ! jq -e '.unfree.drvPath | endswith("facet-unfree-control-1.drv")' "$policy.json"; then
            echo "unfree policy $policy did not expose the control derivation" >&2
            cat "$policy.log" >&2
            exit 1
          fi
        elif (( status == 0 )) || ! grep -F 'facet-unfree-control-1' "$policy.log" | grep -F 'unfree license'; then
          echo "unfree policy $policy did not reject the control for its unfree license" >&2
          cat "$policy.log" >&2
          exit 1
        fi
      done
      mkdir -p "$out"
      cp before.json after.json "$out/"
    '';
}

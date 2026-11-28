# go-floor-drift — assert every Go package's RECORDED floor still matches
# the go.mod of the source it is pinned to.
#
# Go overlays read `sources.goFloor or vu.goFloorUnknown`. `mkGoToolchain`
# refuses the missing/"0" floor when selecting a compiler unless the recipe
# supplies an explicit override. `mkGoFloorFix` can still reach `.src` without
# forcing that compiler, so it can repair the key before vendor extraction.
# This check also catches stale-LOW floors: selecting their recorded compiler
# cannot prove that the recorded requirement still matches the pinned source.
#
# Names come from go-floor-packages.nix so listing checks does not evaluate
# packages. go-floor-declared-list checks both original discovery predicates,
# so an undeclared package cannot silently escape either family of checks.
#
# The comparison itself is `vu.goModFloorFn`, the SAME shell function
# `mkGoFloorFix` uses to write the floor. Writer and gate share one parse
# on purpose: a second copy is how they would come to disagree about what
# the floor is, and that disagreement presents as a check nobody can make
# green.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    vu = import ../../lib/packaging.nix;

    pkgSet = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
    # Rows absent from this system's package set (gluetun off x86_64-linux)
    # are not checks here; `hasAttrByPath` reads only the set's names.
    declared = lib.filterAttrs (name: _: lib.hasAttrByPath (lib.splitString "." name) pkgSet) (import ./go-floor-packages.nix);
    # beads.dolt is nested under beads, so the top-level goFloor scan below
    # never sees it; its floor is guarded through the extract-order check.
    goPackages = lib.mapAttrs (name: _: lib.getAttrFromPath (lib.splitString "." name) pkgSet) (builtins.removeAttrs declared ["beads.dolt"]);

    declaredListCheck = let
      discoveredDrift = lib.filterAttrs (_: p: (p.passthru or {}) ? goFloor) pkgSet;
      discoveredExtract =
        lib.filterAttrs
        (_: p:
          (p.passthru or {}) ? fixGoFloor
          && (p.passthru.fixGoFloor.goFloorDestination or null) == "sidecar")
        pkgSet
        # beads.dolt carries its own sidecar floor one level down.
        // lib.optionalAttrs ((pkgSet.beads.passthru or {}) ? dolt) {
          "beads.dolt" = pkgSet.beads.dolt;
        };
      declaredDriftNames = builtins.attrNames goPackages;
      declaredExtractNames = builtins.attrNames (lib.filterAttrs (_: destination: destination == "sidecar") declared);
      discoveredDriftNames = builtins.attrNames discoveredDrift;
      discoveredExtractNames = builtins.attrNames discoveredExtract;
    in
      assert lib.assertMsg (declaredDriftNames == discoveredDriftNames && declaredExtractNames == discoveredExtractNames)
      "go-floor-declared-list: update go-floor-packages.nix; drift declared=${builtins.toJSON declaredDriftNames}, discovered=${builtins.toJSON discoveredDriftNames}; extract-order declared=${builtins.toJSON declaredExtractNames}, discovered=${builtins.toJSON discoveredExtractNames}";
        pkgs.runCommand "go-floor-declared-list" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          touch "$out"
        '';

    mkCheck = name: p: let
      # NOT always the repo root — oh-my-posh keeps its module under `src/`.
      # Read from passthru so the check and the fixer cannot disagree.
      goModPath = p.passthru.goModPath or "go.mod";
      recorded = p.passthru.goFloor;

      # Both storage modes expose the same repair command.
      remedy = ''"$(nix build --no-link --print-out-paths .#${name}.fixGoFloor)"'';
    in
      pkgs.runCommand "go-floor-drift-${name}" {
        # Deliberately an input: the check must read the go.mod of the
        # source this package is ACTUALLY pinned to, not re-fetch upstream.
        inherit (p) src;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${vu.goModFloorFn {inherit pkgs;}}

        actual=$(go_floor_of "$src/${goModPath}")
        recorded="${recorded}"

        if [ "$recorded" = "${vu.goFloorUnknown}" ]; then
          echo "FAIL: ${name} has no recorded Go floor." >&2
          echo "  its go.mod requires: $actual" >&2
          echo "  the placeholder '${vu.goFloorUnknown}' means the recorded floor" >&2
          echo "  was lost or never refreshed. Restore it before selecting" >&2
          echo "  the compiler or remove a stale recipe override once detected." >&2
          printf '  fix: %s\n' ${lib.escapeShellArg remedy} >&2
          exit 1
        fi

        if [ "$recorded" != "$actual" ]; then
          echo "FAIL: ${name} records a stale Go floor." >&2
          echo "  recorded:      $recorded" >&2
          echo "  its go.mod says: $actual" >&2
          printf '  fix: %s\n' ${lib.escapeShellArg remedy} >&2
          exit 1
        fi

        echo "ok — ${name} floor $recorded matches ${goModPath}" > "$out"
      '';
    # Pin known answers that do not depend on the current package sources.
    # gh exercises a higher toolchain directive in production; the 1.9 / 1.26
    # case also detects lexical sorting rather than numeric version ordering.
    parserCases = {
      numeric-order = {
        directives = "go 1.9\ntoolchain go1.26.0\n";
        expected = "1.26.0";
      };
      # A lower toolchain directive must not overwrite the higher go floor.
      toolchain-lower = {
        directives = "go 1.26.5\ntoolchain go1.24.0\n";
        expected = "1.26.5";
      };
    };
    goMod = name: directives: pkgs.writeText "go.mod-${name}" "module example.com/x\n\n${directives}";
    parserTest =
      pkgs.runCommand "go-floor-parse" {
        missing = goMod "missing" "require github.com/foo/bar v1.2.3\n";
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${vu.goModFloorFn {inherit pkgs;}}

        expect_floor() {
          local name="$1" file="$2" expected="$3" actual
          if ! actual=$(go_floor_of "$file"); then
            printf 'FAIL: %s was rejected, expected floor %s\n' "$name" "$expected" >&2
            exit 1
          fi
          if [ "$actual" != "$expected" ]; then
            printf 'FAIL: %s returned %s, expected %s\n' "$name" "$actual" "$expected" >&2
            exit 1
          fi
        }
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: row: "expect_floor ${name} ${goMod name row.directives} ${row.expected}") parserCases)}

        # The fixer must not record an empty floor from a source with no go directive.
        if go_floor_of "$missing" >/dev/null 2>diagnostic; then
          echo "FAIL: go_floor_of accepted a go.mod with no 'go' directive" >&2
          exit 1
        fi
        grep -F "go-floor: no 'go' directive in $missing" diagnostic
        touch "$out"
      '';
  in
    {
      go-floor-declared-list = declaredListCheck;
      go-floor-parse = parserTest;
    }
    // lib.mapAttrs'
    (name: p: lib.nameValuePair "go-floor-drift-${name}" (mkCheck name p))
    goPackages;
}

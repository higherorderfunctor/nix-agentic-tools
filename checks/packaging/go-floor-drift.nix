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
    # ── Positive controls for the shared parser ──────────────────────
    # These used to be justified by "none of the eight packages carries a
    # `toolchain` directive, so that half of `go_floor_of` is DORMANT".
    # THAT WAS FALSE when written and is corrected here: `gh` is pinned to
    # cli/cli, whose go.mod says `go 1.26.0` + `toolchain go1.26.7`, and
    # gh's recorded floor of 1.26.7 is derived from the TOOLCHAIN line —
    # the `go` line alone would have produced 1.26.0. So the max-of-two
    # branch is live in production, not dormant.
    #
    # The controls are still worth having, for the ordinary reason: they
    # pin the parser's behavior on inputs no currently-pinned package
    # happens to exercise, so a future upstream shape does not silently
    # change what "the floor" means.
    #
    # The ordering case is the one worth having: a string compare puts
    # "1.9" ABOVE "1.26", which is the identical trap `mkGoToolchain`
    # avoids with `lib.versionAtLeast`. `sort -V` is what makes it correct
    # here, and this asserts that rather than trusting it.
    mkParserTest = {
      name,
      goMod,
      expect,
    }:
      pkgs.runCommand "go-floor-parse-${name}" {
        goModFile = pkgs.writeText "go.mod-${name}" goMod;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${vu.goModFloorFn {inherit pkgs;}}

        actual=$(go_floor_of "$goModFile")
        if [ "$actual" != "${expect}" ]; then
          echo "FAIL: go_floor_of/${name} returned '$actual', expected '${expect}'" >&2
          exit 1
        fi
        echo "ok — ${name} -> $actual" > "$out"
      '';

    # NEGATIVE control: a go.mod with no `go` directive must FAIL, not
    # return empty. `mkGoFloorFix` must refuse that source instead of recording
    # an empty floor that cannot select a compiler. A "did it produce output?"
    # test would wave through an empty result.
    parserRejectsMissing =
      pkgs.runCommand "go-floor-parse-rejects-missing" {
        goModFile = pkgs.writeText "go.mod-without-go-directive" ''
          module example.com/x

          require github.com/foo/bar v1.2.3
        '';
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${vu.goModFloorFn {inherit pkgs;}}

        if go_floor_of "$goModFile" 2>/dev/null; then
          echo "FAIL: go_floor_of accepted a go.mod with no 'go' directive" >&2
          exit 1
        fi
        echo "ok — rejected go.mod with no 'go' directive" > "$out"
      '';

    parserTests = {
      go-floor-parse-go-only = mkParserTest {
        name = "go-only";
        goMod = "module example.com/x\n\ngo 1.25.0\n";
        expect = "1.25.0";
      };
      # `toolchain` ABOVE `go` — the directive that raises the real floor.
      go-floor-parse-toolchain-higher = mkParserTest {
        name = "toolchain-higher";
        goMod = "module example.com/x\n\ngo 1.25.0\n\ntoolchain go1.26.5\n";
        expect = "1.26.5";
      };
      # `toolchain` BELOW `go` — `go` still wins; this is a max, not a
      # last-one-wins.
      go-floor-parse-toolchain-lower = mkParserTest {
        name = "toolchain-lower";
        goMod = "module example.com/x\n\ngo 1.26.5\n\ntoolchain go1.24.0\n";
        expect = "1.26.5";
      };
      # The ordering trap: a string compare sorts "1.9" above "1.26".
      go-floor-parse-numeric-order = mkParserTest {
        name = "numeric-order";
        goMod = "module example.com/x\n\ngo 1.9\n\ntoolchain go1.26.0\n";
        expect = "1.26.0";
      };
    };
  in
    parserTests
    // {
      go-floor-declared-list = declaredListCheck;
      go-floor-parse-rejects-missing = parserRejectsMissing;
    }
    // lib.mapAttrs'
    (name: p: lib.nameValuePair "go-floor-drift-${name}" (mkCheck name p))
    goPackages;
}

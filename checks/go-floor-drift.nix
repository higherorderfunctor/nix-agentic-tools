# go-floor-drift — assert every Go package's RECORDED floor still matches
# the go.mod of the source it is pinned to.
#
# This is the loud half of the floor mechanism. Reading the floor is
# silent by construction: a Go overlay reads `sources.goFloor or
# vu.goFloorUnknown`, and `goFloorUnknown` ("0") is satisfied by every
# toolchain, so a missing or stale-LOW floor makes `goToolchainForFloor`
# return `ourGo` and quietly apply no override. That is the exact failure
# this whole mechanism exists to remove, and it cannot be caught at eval
# — `mkGoFloorFix` has to evaluate the package to build its `.src`, so a
# `throw` on the missing key would deadlock the fixer that repairs it.
#
# So eval stays permissive and THIS gates. Same division of labour as the
# extracted sidecars (`checks/<pkg>-extracted.nix`).
#
# NO REGISTRY. The check discovers its own subjects by filtering
# `self.packages.<system>` for `passthru.goFloor`. A registry listing the
# Go packages would be a second source of truth that a new Go package
# could be added without touching — which is precisely how a package ends
# up unprotected. Packages carry the metadata; this consumer derives the
# work list from it.
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
}: let
  vu = import ../overlays/lib.nix;

  goPackages =
    lib.filterAttrs
    (_: p: (p.passthru or {}) ? goFloor)
    self.packages.${pkgs.stdenv.hostPlatform.system};

  mkCheck = name: p: let
    # NOT always the repo root — oh-my-posh keeps its module under `src/`.
    # Read from passthru so the check and the fixer cannot disagree.
    goModPath = p.passthru.goModPath or "go.mod";
    recorded = p.passthru.goFloor;

    # Sidecar-managed packages carry a fixer; trunk-tracked ones (no
    # sidecar, bumped by nix-update) carry a literal. The remedy differs,
    # so name the right one rather than making the reader work it out.
    remedy =
      if (p.passthru or {}) ? fixGoFloor
      then "nix run .#${name}.fixGoFloor   # rewrites the sidecar's goFloor"
      else "edit the `goFloor` literal in this package's overlay .nix";
  in
    pkgs.runCommand "go-floor-drift-${name}" {
      # Deliberately an input: the check must read the go.mod of the
      # source this package is ACTUALLY pinned to, not re-fetch upstream.
      inherit (p) src;
    } ''
      ${vu.goModFloorFn {inherit pkgs;}}

      actual=$(go_floor_of "$src/${goModPath}")
      recorded="${recorded}"

      if [ "$recorded" = "${vu.goFloorUnknown}" ]; then
        echo "FAIL: ${name} has no recorded Go floor." >&2
        echo "  its go.mod requires: $actual" >&2
        echo "  the placeholder '${vu.goFloorUnknown}' means the sidecar key" >&2
        echo "  was destroyed by an update and never restored — the toolchain" >&2
        echo "  seam is silently doing nothing for this package." >&2
        echo "  fix: ${remedy}" >&2
        exit 1
      fi

      if [ "$recorded" != "$actual" ]; then
        echo "FAIL: ${name} records a stale Go floor." >&2
        echo "  recorded:      $recorded" >&2
        echo "  its go.mod says: $actual" >&2
        echo "  fix: ${remedy}" >&2
        exit 1
      fi

      echo "ok — ${name} floor $recorded matches ${goModPath}" > "$out"
    '';
  # ── Positive controls for the shared parser ──────────────────────
  # None of the eight packages currently carries a `toolchain` directive,
  # so that half of `go_floor_of` is DORMANT — exercised by nothing, and
  # therefore free to rot until the first package that needs it. Same
  # reasoning `checks/go-toolchain-floor.nix` gives for covering all three
  # of its branches rather than only the one in use.
  #
  # The ordering case is the one worth having: a string compare puts
  # "1.9" ABOVE "1.26", which is the identical trap `goToolchainForFloor`
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
      ${vu.goModFloorFn {inherit pkgs;}}

      actual=$(go_floor_of "$goModFile")
      if [ "$actual" != "${expect}" ]; then
        echo "FAIL: go_floor_of/${name} returned '$actual', expected '${expect}'" >&2
        exit 1
      fi
      echo "ok — ${name} -> $actual" > "$out"
    '';

  # NEGATIVE control: a go.mod with no `go` directive must FAIL, not
  # return empty. An empty floor is satisfied by every toolchain, so it
  # would make the seam silently do nothing — the precise failure this
  # mechanism exists to remove, and the one a "did it produce output?"
  # test would wave through.
  parserRejectsMissing =
    pkgs.runCommand "go-floor-parse-rejects-missing" {
      goModFile = pkgs.writeText "go.mod-without-go-directive" ''
        module example.com/x

        require github.com/foo/bar v1.2.3
      '';
    } ''
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
  // {go-floor-parse-rejects-missing = parserRejectsMissing;}
  // lib.mapAttrs'
  (name: p: lib.nameValuePair "go-floor-drift-${name}" (mkCheck name p))
  goPackages

# go-toolchain-floor — branch coverage for `goToolchainForFloor` in
# overlays/lib.nix, the seam that fills a Go-version gap between a
# package's go.mod floor and this repo's nixpkgs pin.
#
# WHY A CHECK AND NOT A LIVE CONSUMER. Every Go package this repo carries
# currently declares a floor at or below our pin's `go`, so the helper
# resolves to `ourPkgs.go` for all of them and the go-overlay input never
# instantiates on the package path. That is the design working — the seam
# is self-clearing — but it would ship the input DORMANT, which is the
# same dead-code rule that kept `ghArchiveUpdateScript` and
# `mkGoVendorFix` out of the tree until a slice exercised them. Shipping a
# live-but-redundant toolchain override to "use" the input would be
# strictly worse: it is exactly the silent-downgrade pin the helper exists
# to prevent. So the input is exercised here instead, on the real path —
# real go-bin, real 127-release version table, real selection — with only
# the "our pin is behind" CONDITION simulated.
#
# Eval-only: nothing below builds a toolchain. Only `.version` and
# `.outPath` are forced, both of which resolve from go-overlay's committed
# manifests with no import-from-derivation.
#
# Three branches, one positive control:
#
#   1. floor satisfied by our pin      -> returns `ourGo` itself
#   2. floor above the (simulated) pin -> lowest satisfying go-bin RELEASE
#   3. floor above everything          -> throws (caught with tryEval)
#   +  positive control: go-bin really does carry prereleases, so the
#      release-only filter in branch 2 is doing work rather than being
#      vacuously true.
{
  inputs,
  lib,
  pkgs,
}: let
  vu = import ../overlays/lib.nix;

  # Same instantiation the package files use: THIS repo's pin, with
  # go-overlay applied inside it (the rust-overlay shape).
  goPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  goBin = goPkgs.go-bin;
  ourGo = goPkgs.go;

  resolve = {
    floor,
    ourGo,
  }:
    vu.goToolchainForFloor {
      inherit floor goBin lib ourGo;
      pname = "go-toolchain-floor-check";
    };

  isRelease = v: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" v != null;
  allVersions = builtins.attrNames goBin.versions;
  releases = builtins.sort lib.versionOlder (builtins.filter isRelease allVersions);
  nRel = builtins.length releases;

  # The newest four releases, used to stage branch 2. Taken from the TOP
  # of the table rather than the bottom on purpose: the oldest manifests
  # (1.17…) predate some platform/arch combinations, and this check runs
  # on aarch64-darwin as well as x86_64-linux.
  at = i: builtins.elemAt releases i;
  v1 = at (nRel - 4);
  v2 = at (nRel - 3);
  v3 = at (nRel - 2);
  v4 = at (nRel - 1);

  # Branch 2, staged twice.
  #   gapOne:   pin at v3, floor at v4 — exactly one satisfying release.
  #   gapMulti: pin at v1, floor at v2 — THREE satisfying releases, so the
  #             "lowest" half of the contract is actually under test.
  gapOne = resolve {
    floor = v4;
    ourGo = goBin.versions.${v3};
  };
  gapMulti = resolve {
    floor = v2;
    ourGo = goBin.versions.${v1};
  };

  # The lowest-satisfying property, stated independently of how the helper
  # computes it: no release older than what came back also clears the
  # floor.
  isLowestSatisfying = floor: got:
    lib.versionAtLeast got.version floor
    && !(lib.any (v: lib.versionAtLeast v floor && lib.versionOlder v got.version) releases);

  # Branch 3, bound out of the assertions so the tryEval calls read as
  # plain records rather than parenthesised field selections.
  unsatisfiable = builtins.tryEval (resolve {
    floor = "99.0.0";
    inherit ourGo;
  });
  resolvable = builtins.tryEval (resolve {
    floor = "1.17";
    inherit ourGo;
  });

  mkTest = name: assertion:
    pkgs.runCommand "go-toolchain-floor-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name} (our go ${ourGo.version}; go-bin ${toString nRel} releases, newest ${v4})" > $out''
        else throw "FAIL: go-toolchain-floor ${name}"
      }
    '';
in {
  # ── Branch 1: our pin suffices, go-bin is never reached ─────────────
  go-toolchain-floor-satisfied-far-below = mkTest "satisfied-far-below" (
    (resolve {
      floor = "1.17";
      inherit ourGo;
    })
    .outPath
    == ourGo.outPath
  );

  # A floor EQUAL to our pin still counts as satisfied — `versionAtLeast`,
  # not `versionOlder`. Cheap, and it pins the boundary the one-off-by-one
  # rewrite of this helper would break.
  go-toolchain-floor-satisfied-exactly = mkTest "satisfied-exactly" (
    (resolve {
      floor = ourGo.version;
      inherit ourGo;
    })
    .outPath
    == ourGo.outPath
  );

  # ── Branch 2: the gap is real, go-bin fills it ──────────────────────
  go-toolchain-floor-gap-single = mkTest "gap-single" (
    gapOne.outPath
    != goBin.versions.${v3}.outPath
    && gapOne.version == v4
    && isLowestSatisfying v4 gapOne
  );

  go-toolchain-floor-gap-lowest-of-many = mkTest "gap-lowest-of-many" (
    gapMulti.outPath
    != goBin.versions.${v1}.outPath
    && gapMulti.version == v2
    && isLowestSatisfying v2 gapMulti
    # Proves it did not simply grab the newest.
    && gapMulti.version != v4
  );

  # A resolved toolchain is never a prerelease.
  go-toolchain-floor-gap-skips-prereleases = mkTest "gap-skips-prereleases" (
    isRelease gapOne.version && isRelease gapMulti.version
  );

  # POSITIVE CONTROL for the filter above: go-bin must actually carry
  # prereleases, or "never returns a prerelease" is vacuously true and
  # proves nothing. It carries 26 today (1.17rc1 … 1.27rc2), and
  # `go-bin.latest` is itself one of them.
  go-toolchain-floor-prereleases-exist = mkTest "prereleases-exist" (
    lib.any (v: !(isRelease v)) allVersions
  );

  # ── Branch 3: nothing satisfies the floor -> loud failure ───────────
  go-toolchain-floor-unsatisfiable-throws = mkTest "unsatisfiable-throws" (
    unsatisfiable.success == false
  );

  # POSITIVE CONTROL for the tryEval harness: the same harness must report
  # success on a floor that DOES resolve. Without it, "the throw was
  # caught" cannot be told apart from "tryEval reports failure for
  # everything".
  go-toolchain-floor-tryeval-harness-sane = mkTest "tryeval-harness-sane" (
    resolvable.success == true
  );
}

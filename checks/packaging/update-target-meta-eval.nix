# Every update target must survive nix-update's own evaluation of it.
#
# nix-update starts every package update with
# `nix-instantiate --eval --json --strict nix_update/eval.nix`, which reads a
# fixed set of fields off the package (`meta.changelog`, `src.tag`,
# `goModules.outputHash`, ...) and forces every one. Builds and the rest of
# `nix flake check` never force most of them, so a package can build green
# and still fail every sweep. That happened to gh: nixpkgs 6cce080774 made
# its `meta.changelog` read `finalAttrs.src.tag`, our fetchzip `src` had no
# `tag`, and the lock bump merged green while the gh lane was held back with
# "attribute 'tag' missing".
#
# The field list is NOT restated here. This evaluates the pinned nix-update
# input's own eval.nix against each target, so a field nix-update starts
# reading is checked the day the input is bumped. `scopedImport` replaces the
# one `import importPath` in eval.nix with a function returning this system's
# `ciPackages`, which is the set update-pkg.sh points nix-update at
# (`--flake ciPackages.<system>.<name>`). `isFlake = false` keeps eval.nix off
# `getFlake`, which pure evaluation cannot call; on that branch it only skips
# position sanitizing, which reads no package field.
#
# `toJSON` forces the result as deeply as `--json --strict` does. Its string
# context is discarded so the check stays eval-only: a field such as a cargo
# lockfile path can carry a derivation's context, and keeping it would make
# this check build that derivation.
#
# A field that throws cannot be caught here — `tryEval` does not catch a
# missing attribute — so a broken target fails evaluation of the check, with
# the target named in the error context. The positive control below rigs one
# real target with a throwing `meta.changelog` and confirms the same
# evaluation path reaches it.
{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks.update-target-meta-eval = let
    inherit (pkgs.stdenv.hostPlatform) system;
    packages = self.ciPackages.${system};
    evalNix = "${inputs.nix-update}/nix_update/eval.nix";

    # Targets absent from this system's package set are not evaluated here;
    # list them instead of dropping them silently.
    targetNames = builtins.attrNames self.updateTargets;
    absentTargets = builtins.filter (name: !(builtins.hasAttr name packages)) targetNames;
    presentTargets = builtins.filter (name: builtins.hasAttr name packages) targetNames;

    # nix-update's eval.nix, called the way eval.py calls it, against `set`.
    nixUpdateEval = set: name:
      builtins.scopedImport {import = _: _: set;} evalNix {
        attribute = builtins.toJSON [name];
        importPath = "ciPackages.${system}";
        isFlake = false;
        inherit system;
      };
    forced = set: name:
      builtins.addErrorContext "while evaluating update target '${name}' the way nix-update's eval.nix does"
      (builtins.unsafeDiscardStringContext (builtins.toJSON (nixUpdateEval set name)));

    report = lib.concatMapStrings (name: "  ok  ${name}: ${forced packages name}\n") presentTargets;

    # Positive control: one real target with a throwing meta.changelog must
    # fail the same evaluation.
    controlName = builtins.head presentTargets;
    controlPackages =
      packages
      // {
        ${controlName} = packages.${controlName}.overrideAttrs (prev: {
          meta = (prev.meta or {}) // {changelog = throw "positive control";};
        });
      };
    controlCaught = !(builtins.tryEval (forced controlPackages controlName)).success;
  in
    assert lib.assertMsg controlCaught
    "update-target-meta-eval: rigging ${controlName}.meta.changelog to throw did not fail nix-update's evaluation; the check cannot fail";
    assert lib.assertMsg (presentTargets != []) "update-target-meta-eval: no update target is in ciPackages.${system}";
      pkgs.writeText "update-target-meta-eval" (
        report
        + lib.optionalString (absentTargets != [])
        "not in this system's package set, not evaluated: ${lib.concatStringsSep " " absentTargets}\n"
      );
}

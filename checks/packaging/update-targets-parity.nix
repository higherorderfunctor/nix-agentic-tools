# Update-target completeness + parity gate (packages ↔ config.update.targets ↔
# owner recipes).
#
# config/update-matrix.nix was dissolved into config.update.targets, so this is
# now the SOLE update-target gate — there is no coexisting matrix to reconcile.
# config.update.targets composes owner registry.nix contributions with root
# workspace policy. The `.#updateTargets` flake output is the
# single source of truth the pipeline reads.
#
# The reverse packages → targets direction asserts that every versioned flake
# package is updated by a same-name row, a row covering the same derivation,
# source, or update script, a declared flake-input owner, or an explicit
# excludePatterns exemption. This makes an absent package row visible without
# replacing the declared update registry with package discovery.
#
# In the forward targets → recipes direction, every main-tracking target (one
# carrying a `git` URL — binary `--use-update-script` packages manage their own
# sources and never hit resolve_recipe_file) must satisfy three assertions,
# folding in the old checks/overlay-target-resolution.nix regression gate:
#   (a) `file` is non-null (main-tracking packages MUST declare a recipe).
#   (b) `file` == resolve_recipe_file(<git>, packages) — byte-identical to the
#       exact string update-pkg.sh consumes, so the declared path can never
#       drift from what the deterministic resolver would otherwise pick.
#   (c) that resolved file carries an inline 40-hex `rev = "…"`, so the rev-bump
#       actually has something to sed (a mis-resolution to a rev-less file would
#       silently freeze the package).
#
# Runs the SAME resolver (dev/scripts/resolve-recipe-file.sh) the pipeline
# uses, against the SAME owner package trees.
{
  inputs,
  lib,
  pkgs,
  self,
  updateRegistry,
  ...
}: {
  checks.update-targets-parity = let
    inherit (self) updateTargets;
    packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
    versionedPackages = lib.filterAttrs (_: package: package ? version) packages;
    targetPackageNames = builtins.filter (name: builtins.hasAttr name packages) (builtins.attrNames updateTargets);
    targetPackages = map (name: packages.${name}) targetPackageNames;

    sourcePath = package: let
      source = package.updateSource or (package.src or null);
    in
      if builtins.isAttrs source && source ? outPath
      then source.outPath
      else null;
    updateScriptPath = package:
      if package ? updateScript && lib.isDerivation package.updateScript
      then package.updateScript.drvPath
      else null;
    updateFlakeInput = package: let
      passthru = package.passthru or {};
    in
      passthru.updateFlakeInput or null;
    updateTargetExemption = package: let
      passthru = package.passthru or {};
    in
      passthru.updateTargetExempt or null;
    sharesWithTarget = coveredTargets: accessor: package: let
      value = accessor package;
    in
      value != null && builtins.any (target: accessor target == value) coveredTargets;
    explicitlyExcluded = name:
      builtins.any (pattern: builtins.match pattern name != null) updateRegistry.excludePatterns;
    coverageFor = targets: coveredTargets: name: package: let
      inputOwner = updateFlakeInput package;
      exemption = updateTargetExemption package;
    in
      if builtins.hasAttr name targets
      then "target row"
      else if builtins.any (target: package.drvPath == target.drvPath) coveredTargets
      then "shared derivation with a target"
      else if sharesWithTarget coveredTargets sourcePath package
      then "shared source with a target"
      else if sharesWithTarget coveredTargets updateScriptPath package
      then "shared update script with a target"
      else if builtins.isString inputOwner && builtins.hasAttr inputOwner inputs
      then "flake input ${inputOwner}"
      else if builtins.isString exemption && builtins.stringLength exemption > 0
      then "package exemption: ${exemption}"
      else if explicitlyExcluded name
      then "explicit excludePatterns exemption"
      else null;
    packageCoverage = lib.mapAttrs (coverageFor updateTargets targetPackages) versionedPackages;
    uncoveredPackages = lib.filterAttrs (_: coverage: coverage == null) packageCoverage;

    # Positive control: context7-mcp is a real, uniquely sourced package row.
    # Removing it must make that versioned package uncovered, proving the reverse
    # direction can fail rather than merely reporting the current registry.
    positiveControlName = "context7-mcp";
    positiveControlTargets = builtins.removeAttrs updateTargets [positiveControlName];
    positiveControlTargetNames = builtins.filter (name: builtins.hasAttr name packages) (builtins.attrNames positiveControlTargets);
    positiveControlPackages = map (name: packages.${name}) positiveControlTargetNames;
    positiveControlPass =
      builtins.hasAttr positiveControlName packages
      && coverageFor positiveControlTargets positiveControlPackages positiveControlName packages.${positiveControlName} == null;
    coverageFile = pkgs.writeText "update-target-package-coverage.txt" (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: coverage: "${name}: ${
            if coverage == null
            then "MISSING"
            else coverage
          }"
        )
        packageCoverage
      )
    );
    uncoveredFile = pkgs.writeText "update-target-uncovered-packages.txt" (
      lib.concatStringsSep "\n" (builtins.attrNames uncoveredPackages)
    );

    # Only entries that carry a `git` URL go through rev-bump resolution
    # (main-tracking packages); binary packages have `git = null`.
    gitEntries = lib.filterAttrs (_: v: v.git != null) updateTargets;
    # "name<TAB>git-url<TAB>declared-file" per line — name is for diagnostics. A
    # null `file` is emitted as the empty string so assertion (a) can flag it.
    table = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: v: "${name}\t${v.git}\t${
          if v.file == null
          then ""
          else v.file
        }"
      )
      gitEntries
    );
    tableFile = pkgs.writeText "update-targets-parity.tsv" table;

    # An update target whose package carries a census (`passthru.extracted`)
    # and is NOT bumped through its own `--use-update-script` (whose
    # `extraExtract` regenerates the sidecar) must expose
    # `regenerateExtracted`: update-pkg.sh runs it after the rev bump and
    # nix-update, and nothing else would refresh the sidecar.
    staleCensusTargets = builtins.filter (name: let
      passthru = packages.${name}.passthru or {};
    in
      passthru ? extracted
      && !(passthru ? regenerateExtracted)
      && !(lib.elem "--use-update-script" (updateTargets.${name}.flags or [])))
    targetPackageNames;

    # Every update target participating in Go-floor drift detection must expose
    # the writer for its recorded floor. Release targets invoke it through
    # mkGoUpdateExtract; rev-tracked targets are refreshed by update-pkg.sh
    # before nix-update evaluates their dependency derivations.
    missingGoFloorWriters = builtins.filter (name: let
      passthru = packages.${name}.passthru or {};
    in
      passthru ? goFloor && !(passthru ? fixGoFloor))
    targetPackageNames;

    # The updater invokes recipe writers directly for rev-tracked targets and
    # leaves sidecar writers inside --use-update-script. Keep the helper mode
    # aligned with that routing so neither path silently writes at the wrong
    # point in the update sequence.
    incorrectGoFloorDestinations = builtins.filter (name: let
      target = updateTargets.${name};
      passthru = packages.${name}.passthru or {};
      expectedDestination =
        if lib.elem "--use-update-script" (target.flags or [])
        then "sidecar"
        else if target.git or null != null
        then "recipe"
        else null;
      actualDestination = (passthru.fixGoFloor or {}).goFloorDestination or null;
    in
      passthru ? goFloor
      && expectedDestination != null
      && actualDestination != expectedDestination)
    targetPackageNames;

    # Every sidecar a package's `regenerateExtracted` writes must be a
    # committed file: the update scripts stage exactly these paths, and a
    # wrong one aborts the whole `git add`.
    regeneratedSidecars =
      lib.unique (lib.concatMap (package: package.passthru.regenerateExtracted.sidecars)
        (builtins.filter (package: (package.passthru or {}) ? regenerateExtracted) (builtins.attrValues packages)));
    sidecarsFile = pkgs.writeText "update-targets-regenerated-sidecars.txt" (lib.concatStringsSep "\n" regeneratedSidecars);
  in
    pkgs.runCommandLocal "update-targets-parity-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
      src = ../..;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      cd "$src"
      # shellcheck source=dev/scripts/resolve-recipe-file.sh
      source dev/scripts/resolve-recipe-file.sh

      if [ "${lib.boolToString positiveControlPass}" != true ]; then
        echo "ERROR: removing the context7-mcp row did not make its package uncovered" >&2
        exit 1
      fi

      if [ -n "${toString staleCensusTargets}" ]; then
        echo "ERROR: update targets with passthru.extracted but no sidecar regeneration: ${toString staleCensusTargets}" >&2
        echo "Give each passthru.regenerateExtracted (packageLib.mkRegenerateExtracted)." >&2
        exit 1
      fi

      if [ -n "${toString missingGoFloorWriters}" ]; then
        echo "ERROR: update targets with passthru.goFloor but no passthru.fixGoFloor: ${toString missingGoFloorWriters}" >&2
        echo "Give each package a packageLib.mkGoFloorFix writer." >&2
        exit 1
      fi

      if [ -n "${toString incorrectGoFloorDestinations}" ]; then
        echo "ERROR: Go-floor fixer destination disagrees with update routing: ${toString incorrectGoFloorDestinations}" >&2
        echo "Use sidecar for --use-update-script targets and recipe for rev-tracked targets." >&2
        exit 1
      fi

      if [ ! -s ${sidecarsFile} ]; then
        echo "ERROR: no package exposes passthru.regenerateExtracted, though Semble's snapshots alone need one" >&2
        exit 1
      fi
      while IFS= read -r sidecar || [ -n "$sidecar" ]; do
        if [ ! -f "$sidecar" ]; then
          echo "ERROR: passthru.regenerateExtracted names $sidecar, which is not a committed file" >&2
          exit 1
        fi
      done < ${sidecarsFile}

      echo "Versioned flake package update coverage:"
      cat ${coverageFile}
      if [ -s ${uncoveredFile} ]; then
        echo "" >&2
        echo "ERROR: versioned flake packages lack an update target or a property-based exemption:" >&2
        cat ${uncoveredFile} >&2
        exit 1
      fi

      # An empty set means every main-tracking target lost its `git` URL — the
      # dissolved registry is expected to carry ~18 of them. Fail loudly rather
      # than pass by absence.
      if [ ! -s ${tableFile} ]; then
        echo "ERROR: no config.update.targets entry carries a git URL. The" >&2
        echo "dissolved registry expects ~18 main-tracking targets — did the" >&2
        echo "update-target wiring get dropped?" >&2
        exit 1
      fi

      failures=""
      # `|| [ -n "$name" ]` processes the final line even though the TSV has no
      # trailing newline (concatStringsSep produces none): otherwise bash `read`
      # returns non-zero at EOF and the last alphabetical entry is silently
      # skipped — never validated.
      while IFS=$'\t' read -r name url declared || [ -n "$name" ]; do
        [ -z "$name" ] && continue
        # (a) main-tracking targets MUST declare a recipe file.
        if [ -z "$declared" ]; then
          failures="$failures"$'\n'"  $name: has a git URL but config.update.targets.$name.file is null"
          continue
        fi
        # (b) declared file must be byte-identical to the resolver output.
        if ! resolved=$(resolve_recipe_file "$url" packages 2>&1); then
          failures="$failures"$'\n'"  $name: resolver failed: $resolved"
          continue
        fi
        if [ "$resolved" != "$declared" ]; then
          failures="$failures"$'\n'"  $name: config.update.targets.$name.file = '$declared' but resolve_recipe_file printed '$resolved'"
          continue
        fi
        # (c) the resolved file must carry an inline 40-hex rev to sed-bump.
        if ! grep -qE 'rev = "[a-f0-9]{40}' "$resolved"; then
          failures="$failures"$'\n'"  $name: resolved $resolved but it has no inline 40-hex rev"
          continue
        fi
        echo "  ok  $name -> $declared (byte-identical to resolver, inline rev present)"
      done < ${tableFile}

      if [ -n "$failures" ]; then
        echo "" >&2
        echo "ERROR: config.update.targets.<name>.file diverges from the" >&2
        echo "deterministic resolver the update pipeline uses, or the resolved" >&2
        echo "recipe lacks an inline rev (see checks/packaging/update-targets-parity.nix):" >&2
        echo "$failures" >&2
        exit 1
      fi

      echo "All versioned flake packages are update-covered; main-tracking targets match resolve_recipe_file output and carry an inline rev."
      mkdir -p "$out"
      touch "$out/ok"
    '';
}

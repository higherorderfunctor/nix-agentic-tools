# beads — stable `bd` releases and their paired Dolt runtime on one repository
# update cadence. The bases are nixpkgs' beads and Dolt recipes, so their build
# inputs and package mechanics remain upstream-owned. This overlay changes both
# pins atomically and extends Beads' ONE inherited wrapper with telemetry
# controls; it never wraps the already-wrapped result again.
# cspell:ignore dolthub gastownhall
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  beadsSources = builtins.fromJSON (builtins.readFile ./beads-sources.json);
  beadsSourcesFile = "overlays/dev-tools/beads-sources.json";
  doltSources = builtins.fromJSON (builtins.readFile ./beads-dolt-sources.json);
  doltSourcesFile = "overlays/dev-tools/beads-dolt-sources.json";

  beadsGoUpdate = vu.mkGoUpdateExtract {
    attr = "beads";
    pkgs = ourPkgs;
    pname = "beads";
    sourcesFile = beadsSourcesFile;
  };
  beadsFixGoFloor = beadsGoUpdate.fixGoFloor;
  beadsFixVendorHash = beadsGoUpdate.fixVendorHash;

  beadsGoFloor = beadsSources.goFloor or vu.goFloorUnknown;

  doltGoUpdate = vu.mkGoUpdateExtract {
    attr = "beads.dolt";
    goModPath = "go/go.mod";
    pkgs = ourPkgs;
    pname = "beads-dolt";
    sourcesFile = doltSourcesFile;
  };
  doltFixGoFloor = doltGoUpdate.fixGoFloor;
  doltFixVendorHash = doltGoUpdate.fixVendorHash;

  doltGoFloor = doltSources.goFloor or vu.goFloorUnknown;

  doltUpdateScript = vu.ghArchiveUpdateScript {
    # ORDER is owned by `vu.mkGoUpdateExtract`, not restated here. It was
    # restated here, and it was wrong: the vendor fixer compiles Go and
    # so must follow the floor fixer.
    extraExtract = "${doltGoUpdate.extract}";
    pkgs = ourPkgs;
    pname = "beads-dolt";
    repo = "dolthub/dolt";
    sourcesFile = doltSourcesFile;
  };

  dolt =
    (ourPkgs.dolt.override {
      buildGoModule = vu.mkGoBuilder {
        floor = doltGoFloor;
        pkgs = ourPkgs;
        pname = "beads-dolt";
      };
    })
    .overrideAttrs (prev: {
      inherit (doltSources) version;
      src = fetchzip {inherit (doltSources.src) url hash;};
      vendorHash = doltSources.vendorHash or lib.fakeHash;
      passthru =
        (prev.passthru or {})
        // {
          fixGoFloor = doltFixGoFloor;
          fixVendorHash = doltFixVendorHash;
          goUpdateExtract = doltGoUpdate.extract;
          goFloor = doltGoFloor;
          updateScript = doltUpdateScript;
        };
    });

  beadsUpdateScript = vu.ghArchiveUpdateScript {
    # ORDER is owned by `vu.mkGoUpdateExtract`, not restated here. It was
    # restated here, and it was wrong: the vendor fixer compiles Go and
    # so must follow the floor fixer.
    extraExtract = "${beadsGoUpdate.extract}";
    pkgs = ourPkgs;
    pname = "beads";
    repo = "gastownhall/beads";
    sourcesFile = beadsSourcesFile;
  };

  fixVendorHash = ourPkgs.writeShellScript "fix-vendor-beads-pair" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${beadsFixVendorHash}
    ${doltFixVendorHash}
  '';

  updateScript = ourPkgs.writeShellScript "update-beads-pair" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${beadsUpdateScript}
    ${doltUpdateScript}
  '';
in
  (ourPkgs.beads.override {
    buildGoModule = vu.mkGoBuilder {
      floor = beadsGoFloor;
      pkgs = ourPkgs;
      pname = "beads";
    };
    inherit dolt;
  })
  .overrideAttrs (prev: let
    wrapperAnchor = "wrapProgram $out/bin/bd";
    wrapperWithTelemetry = ''
      wrapProgram $out/bin/bd \
        --set BD_DISABLE_EVENT_FLUSH 1 \
        --set BD_DISABLE_METRICS 1 \
        --set DOLT_DISABLE_EVENT_FLUSH 1'';
  in {
    inherit (beadsSources) version;
    src = fetchzip {inherit (beadsSources.src) url hash;};
    vendorHash = beadsSources.vendorHash or lib.fakeHash;

    # This test installs `#!/usr/bin/env sh` hooks and then asks git to execute
    # them while creating a worktree. The Nix build sandbox intentionally has
    # no `/usr/bin/env`, so the hook fails before exercising Beads' worktree
    # path assertion. Preserve nixpkgs' existing skip regex and extend it at
    # the one anchored seam; fail evaluation if that upstream shape moves.
    checkFlags = let
      inherited = prev.checkFlags or [];
      extendSkip = flag:
        if lib.hasPrefix "-skip=^(" flag && lib.hasSuffix ")$" flag
        then "${lib.removeSuffix ")$" flag}|TestInstallHooksBeads_WorktreeAccess)$"
        else flag;
    in
      if
        builtins.length inherited
        == 1
        && lib.hasPrefix "-skip=^(" (builtins.head inherited)
        && lib.hasSuffix ")$" (builtins.head inherited)
      then map extendSkip inherited
      else throw "beads: nixpkgs checkFlags no longer has the expected single anchored skip regex";

    postInstall =
      if lib.hasInfix wrapperAnchor prev.postInstall
      then lib.replaceString wrapperAnchor wrapperWithTelemetry prev.postInstall
      else throw "beads: nixpkgs no longer provides the expected single bd wrapper";

    installCheckPhase = ''
      runHook preInstallCheck

      test -x "$out/bin/bd"
      test -x "$out/bin/.bd-wrapped"
      test "$(${ourPkgs.findutils}/bin/find "$out/bin" -maxdepth 1 -name '.bd-wrapped*' -print | ${ourPkgs.coreutils}/bin/wc -l)" -eq 1
      ${ourPkgs.gnugrep}/bin/grep -aF 'BD_DISABLE_EVENT_FLUSH=1' "$out/bin/bd"
      ${ourPkgs.gnugrep}/bin/grep -aF 'BD_DISABLE_METRICS=1' "$out/bin/bd"
      ${ourPkgs.gnugrep}/bin/grep -aF 'DOLT_DISABLE_EVENT_FLUSH=1' "$out/bin/bd"
      ${ourPkgs.gnugrep}/bin/grep -aF '${lib.makeBinPath [dolt]}' "$out/bin/bd"
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" --version | ${ourPkgs.gnugrep}/bin/grep -F "${beadsSources.version}"
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" metrics | ${ourPkgs.gnugrep}/bin/grep -F 'Anonymous usage metrics: OFF'
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" dolt --help > /dev/null

      runHook postInstallCheck
    '';

    passthru =
      (prev.passthru or {})
      // {
        fixGoFloor = beadsFixGoFloor;
        goFloor = beadsGoFloor;
        # BEADS' OWN chain, not the pair wrapper. `fixVendorHash` below
        # is deliberately the pair script (it repairs both sidecars in
        # one run), but `checks/go-floor-extract-order.nix` has to read a
        # FLAT chain — a pair wrapper only contains the sub-script paths
        # and would hide the ordering it exists to gate.
        goUpdateExtract = beadsGoUpdate.extract;
        inherit fixVendorHash updateScript;
        # The lifecycle module must launch the exact Dolt paired with this
        # Beads build. Exposing that already-used dependency as metadata avoids
        # a second, independently drifting package choice in the module.
        inherit dolt;
      };
  })

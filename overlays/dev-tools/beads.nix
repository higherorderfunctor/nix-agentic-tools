# beads — stable `bd` releases on this repository's update cadence. The base
# is nixpkgs' beads recipe, so its ICU linkage, completion installation,
# platform workarounds, tests, and single Dolt PATH wrapper remain upstream-
# owned. This overlay changes the pin and extends that ONE wrapper with
# telemetry controls; it never wraps the already-wrapped result again.
# cspell:ignore gastownhall
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

  sources = builtins.fromJSON (builtins.readFile ./beads-sources.json);
  sourcesFile = "overlays/dev-tools/beads-sources.json";

  fixVendorHash = vu.mkGoVendorFix {
    attr = "beads";
    pkgs = ourPkgs;
    pname = "beads";
    inherit sourcesFile;
  };

  fixGoFloor = vu.mkGoFloorFix {
    attr = "beads";
    pkgs = ourPkgs;
    pname = "beads";
    inherit sourcesFile;
  };

  goFloor = sources.goFloor or vu.goFloorUnknown;
in
  (ourPkgs.beads.override {
    buildGoModule = vu.mkGoBuilder {
      floor = goFloor;
      pkgs = ourPkgs;
      pname = "beads";
    };
  })
  .overrideAttrs (prev: let
    wrapperAnchor = "wrapProgram $out/bin/bd";
    wrapperWithTelemetry = ''
      wrapProgram $out/bin/bd \
        --set BD_DISABLE_EVENT_FLUSH 1 \
        --set BD_DISABLE_METRICS 1 \
        --set DOLT_DISABLE_EVENT_FLUSH 1'';
  in {
    inherit (sources) version;
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;

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
      if builtins.length inherited == 1 && lib.hasPrefix "-skip=^(" (builtins.head inherited)
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
      ${ourPkgs.gnugrep}/bin/grep -aF '${lib.makeBinPath [ourPkgs.dolt]}' "$out/bin/bd"
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" --version | ${ourPkgs.gnugrep}/bin/grep -F "${sources.version}"
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" metrics | ${ourPkgs.gnugrep}/bin/grep -F 'Anonymous usage metrics: OFF'
      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/bd" dolt --help > /dev/null

      runHook postInstallCheck
    '';

    passthru =
      (prev.passthru or {})
      // {
        inherit fixGoFloor fixVendorHash goFloor;
        updateScript = vu.ghArchiveUpdateScript {
          extraExtract = ''
            ${fixVendorHash}
            ${fixGoFloor}
          '';
          pkgs = ourPkgs;
          pname = "beads";
          repo = "gastownhall/beads";
          inherit sourcesFile;
        };
      };
  })

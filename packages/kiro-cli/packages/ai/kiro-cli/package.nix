# Kiro CLI — the pinned standalone release, with its own FHS env on Linux.
# Per-platform sources in sources.json, managed by updateScript.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchurl makeWrapper;
  inherit (pkgs.stdenv.hostPlatform) system;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);

  # The release manifest's selector per Nix system is the single source for
  # the supported systems; the fetched URL per system is the one the updater
  # wrote to sources.json from that manifest. Since 3.0.0 both platforms ship
  # the same `kirocli/bin/kiro-cli` tarball layout; Darwin's is one universal
  # binary.
  release = import ../../../lib/release.nix;

  # Every platform's release is fetchable on any host, which is what lets one
  # host extract them all. The explicit name carries the version, because the
  # URL basename does not.
  releaseSourceFor = target:
    fetchurl {
      inherit (sources.${target}) hash url;
      name = "kiro-cli-source-${sources.version}-${target}.tar.gz";
    };
  # Both selected prompt patches and rollout features follow every public,
  # direct and FHS payload route. The native output binds one selected KAS;
  # KAS depends only on the fetched release input, never on the native output.
  releaseSource =
    if release.selectors ? ${system}
    then releaseSourceFor system
    else throw "kiro-cli: unsupported system ${system}";
  sourceRoot = "kirocli";
  mkKas = import ../../../lib/kas.nix {
    inherit pkgs sourceRoot;
    src = releaseSource;
    inherit (sources) version;
  };
  canonFeatures = fs: pkgs.lib.sort (a: b: a < b) (pkgs.lib.unique fs);

  mkKiroCliWithPayload = rawFeatures: bundlePatches: let
    kas = mkKas bundlePatches;
    managedKas = (bundlePatches.replace or []) != [];
    # Defaults updates off and normalizes an explicit opt-in. Each packaged
    # command is a direct last hop to the binary, so the guard runs once per
    # launch and needs no state passed to another guard.
    autoUpdateGuard = pkgs.lib.escapeShellArg ''
      nat_kiro_no_auto_update="''${KIRO_NO_AUTO_UPDATE-1}"
      case "''${nat_kiro_no_auto_update,,}" in
        ""|0|false|off|no) unset KIRO_NO_AUTO_UPDATE ;;
        *) export KIRO_NO_AUTO_UPDATE=1 ;;
      esac
      unset nat_kiro_no_auto_update
    '';
    autoUpdateWrapperFlags = "--run 'set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :' --run ${autoUpdateGuard}";
    wrapperFlags = "--set-default TERM xterm-256color ${autoUpdateWrapperFlags} ${
      if managedKas
      then "--set"
      else "--set-default"
    } KIRO_KAS_SERVER_PATH ${kas}/node_modules/@kiro/agent/dist/server/acp-server.js --set-default KIRO_KAS_NODE_PATH ${pkgs.nodejs}/bin/node";
    rolloutFeatures = canonFeatures rawFeatures;

    # Name infix that makes a PATCHED build self-identifying. Both variants
    # were named `kiro-cli-unwrapped-<version>` and differed only by store
    # hash, so a leaked patched binary was indistinguishable from the stock
    # one in a cache listing — which is exactly how one sat unnoticed in the
    # public cache. Derived from the canonicalized feature list, so it names
    # WHICH features were unlocked, with a count and digest when the full
    # names would exceed Nix's derivation-name limit.
    #
    # Consumed only inside `optionalAttrs (rolloutFeatures != [])` blocks:
    # renaming the DEFAULT derivation would fork its drvPath for every
    # consumer and cost the cache hit the `[]` path exists to preserve.
    readableRolloutSuffix = "rollout-" + pkgs.lib.concatStringsSep "-" rolloutFeatures;
    rolloutSuffix =
      if builtins.stringLength "kiro-cli-unwrapped-${readableRolloutSuffix}-${sources.version}" < 200
      then readableRolloutSuffix
      else "rollout-${toString (builtins.length rolloutFeatures)}-${builtins.substring 0 12 (builtins.hashString "sha256" (pkgs.lib.concatStringsSep "," rolloutFeatures))}";

    # The payload is owned here rather than layered on nixpkgs'
    # `kiro-cli-unwrapped`, whose install phase names the pre-3.0 files
    # (`kiro-cli-chat`, `kiro-cli-term`, a Darwin `.app` from a DMG) that the
    # standalone tarballs no longer ship.
    pinned = pkgs.stdenv.mkDerivation ({
        pname = "kiro-cli-unwrapped";
        inherit (sources) version;
        src = releaseSource;
        inherit sourceRoot;

        __structuredAttrs = true;
        strictDeps = true;

        nativeBuildInputs =
          [makeWrapper]
          ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
        # The Linux ELF needs only libgcc_s beyond glibc.
        buildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;

        # `versionCheckHook` runs the wrapped `kiro-cli --version`; the
        # rollout variant appends its own `postInstallCheck`, which only runs
        # because `doInstallCheck` is set.
        nativeInstallCheckInputs = [pkgs.versionCheckHook];
        doInstallCheck = true;

        dontConfigure = true;
        dontBuild = true;
        # The binary embeds compressed runtimes the extractors locate by
        # offset; stripping would rewrite it for no benefit.
        dontStrip = true;

        # The header is scoped to a subshell: stdenv runs every phase in one
        # shell, and versionCheckHook's installCheck reads unset variables.
        installPhase = ''
          runHook preInstall
          (
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            install -Dm755 bin/kiro-cli -t "$out/bin"
          )
          runHook postInstall
        '';

        postFixup =
          ''
            wrapProgram "$out/bin/kiro-cli" ${wrapperFlags}
          ''
          # Deliberately AFTER the wrappers: the patcher finds the binary by
          # content, so it is indifferent to how wrappers renamed it, and
          # running last means it sees the final layout instead of guessing at
          # it.
          + pkgs.lib.optionalString (rolloutFeatures != [])
          (vu.mkKiroRolloutPatch {
            features = rolloutFeatures;
            inherit pkgs;
          });

        passthru = {
          updateScript = release.mkUpdateScript {
            sourcesFile = repoPath ../../../sources.json;
            inherit pkgs;
          };

          inherit autoUpdateWrapperFlags kas;
          withBundlePatches = patches: mkKiroCliWithPayload rawFeatures patches;
          withRolloutFeatures = features: mkKiroCliWithPayload features bundlePatches;
        };

        meta = {
          description = "Kiro CLI, the terminal agent from AWS (pinned standalone release)";
          homepage = "https://kiro.dev";
          license = pkgs.lib.licenses.unfree;
          mainProgram = "kiro-cli";
          platforms = builtins.attrNames release.selectors;
          sourceProvenance = [pkgs.lib.sourceTypes.binaryNativeCode];
        };
      }
      # `optionalAttrs`, NOT an `optionalString` inside an always-present attr.
      # An empty `postInstallCheck` would still land in the build env and fork
      # the default drvPath for every consumer who never enables a feature.
      // pkgs.lib.optionalAttrs (rolloutFeatures != []) {
        # The proprietary binary the rollout patch rewrites.
        pname = "kiro-cli-unwrapped-${rolloutSuffix}";
        postInstallCheck = vu.kiroRolloutVerify;
      });

    # Every platform's release, read statically on this host: no binary is
    # executed, so PR CI and the drift check measure every platform from one
    # host. IFD-safe: consumed ONLY by `nix build` (PR CI + drift check), never
    # readFile'd at eval.
    #
    # x86_64-linux's raw also carries the option tables of the payload's
    # `--help`, the one extraction that executes the binary
    # (`vu.mkKiroHelpExtract`). They are measured on x86_64-linux only: clap
    # compiles each platform's tables from one source, and Darwin runners are
    # capped, so no Darwin host-run job exists. `extracted/facts.json` declares
    # `cli.options` for that system alone, and the Darwin raw never carries it.
    extracted = pkgs.lib.mapAttrs (target: _: let
      static = pkgs.runCommandLocal "kiro-cli-${target}-extracted.json" {} (vu.mkKiroExtract {
        architecture = (pkgs.lib.systems.elaborate target).parsed.cpu.name;
        inherit pkgs;
        release = releaseSourceFor target;
      });
    in
      if target == "x86_64-linux" && system == target
      then
        pkgs.runCommandLocal "kiro-cli-${target}-extracted-help.json" {} (vu.mkKiroHelpExtract {
          binary = "${pinned}/bin/kiro-cli";
          inherit pkgs static;
        })
      else static)
    release.selectors;

    # `unwrapped` names the direct payload on both platforms, which the
    # locator's failure text and `useFhsSandbox = false` rely on.
    passthru =
      pinned.passthru
      // {
        inherit extracted;
        unwrapped = pinned;
      };

    # Rollout builds are renamed at the exported attribute as well as at the
    # payload, so a patched build is identifiable where consumers install it.
    # The default keeps its name, because renaming it would fork its drvPath
    # for every consumer.
    exportedName = "kiro-cli-${rolloutSuffix}";
  in
    if pkgs.stdenv.hostPlatform.isLinux
    then
      # One minimal FHS env supplies the standard loader path and libstdc++/
      # libgcc_s the generic-glibc `bun` that Kiro extracts at runtime needs, so
      # the extracted asset is never patched. 3.0.0 ships one command, so the
      # env's entry point execs it directly and `bin/` holds only `kiro-cli`.
      pkgs.buildFHSEnv ({
          pname = "kiro-cli";
          inherit (sources) version;
          runScript = "${pinned}/bin/kiro-cli";
          # wl-clipboard: Kiro shells out to wl-copy/wl-paste on Wayland.
          targetPkgs = p: [
            pinned
            p.stdenv.cc.cc.lib
            p.wl-clipboard
          ];
          inherit passthru;
          inherit (pinned) meta;
        }
        // pkgs.lib.optionalAttrs (rolloutFeatures != []) {
          name = "${exportedName}-${sources.version}";
        })
    else
      pinned.overrideAttrs (old: {
        passthru = old.passthru // passthru;
        pname =
          if rolloutFeatures != []
          then exportedName
          else "kiro-cli";
      });

  mkKiroCli = rawFeatures: mkKiroCliWithPayload rawFeatures {};
in
  mkKiroCli []

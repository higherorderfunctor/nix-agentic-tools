# Kiro CLI — the pinned standalone release, wrapped by nixpkgs' public package.
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

  # Release-asset URL per Nix system: the single source for the fetched
  # sources, the updateScript's URL templates and `meta.platforms`. A PR build
  # that fetches a platform's tarball therefore proves the URL the updater
  # will prefetch for it. Since 3.0.0 both platforms ship the same
  # `kirocli/bin/kiro-cli` tarball layout; Darwin's is one universal binary.
  releaseUrls = {
    "aarch64-darwin" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/kirocli-universal-darwin.tar.gz";
    "x86_64-linux" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/kirocli-x86_64-linux.tar.gz";
  };

  # Every platform's release is fetchable on any host, which is what lets one
  # host extract them all. The explicit name carries the version, because the
  # URL basename does not.
  releaseSourceFor = target:
    fetchurl {
      url = releaseUrls.${target} sources.version;
      inherit (sources.${target}) hash;
      name = "kiro-cli-source-${sources.version}-${target}.tar.gz";
    };
  # Both selected prompt patches and rollout features follow every public,
  # direct and FHS payload route. The native output binds one selected KAS;
  # KAS depends only on the fetched release input, never on the native output.
  releaseSource =
    if releaseUrls ? ${system}
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
          updateScript = vu.mkUpdateScript {
            sourcesFile = repoPath ../../../sources.json;
            pname = "kiro-cli";
            versionCheck.cmd = "${pkgs.curl}/bin/curl -s https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json | ${pkgs.jq}/bin/jq -r '.version'";
            platforms = releaseUrls;
            inherit pkgs;
          };

          # Every platform's release, read statically on this host: no
          # binary is executed, so PR CI and the drift check measure every
          # platform from one host. IFD-safe: consumed ONLY by `nix build`
          # (PR CI + drift check), never readFile'd at eval.
          extracted = pkgs.lib.mapAttrs (target: _:
            pkgs.runCommandLocal "kiro-cli-${target}-extracted.json" {} (vu.mkKiroExtract {
              architecture = (pkgs.lib.systems.elaborate target).parsed.cpu.name;
              inherit pkgs;
              release = releaseSourceFor target;
            }))
          releaseUrls;

          inherit autoUpdateWrapperFlags kas;
          withBundlePatches = patches: mkKiroCliWithPayload rawFeatures patches;
          withRolloutFeatures = features: mkKiroCliWithPayload features bundlePatches;
        };

        meta = {
          description = "Kiro CLI, the terminal agent from AWS (pinned standalone release)";
          homepage = "https://kiro.dev";
          license = pkgs.lib.licenses.unfree;
          mainProgram = "kiro-cli";
          platforms = builtins.attrNames releaseUrls;
          sourceProvenance = [pkgs.lib.sourceTypes.binaryNativeCode];
        };
      }
      # `optionalAttrs`, NOT an `optionalString` inside an always-present attr.
      # An empty `postInstallCheck` would still land in the build env and fork
      # the default drvPath for every consumer who never enables a feature.
      // pkgs.lib.optionalAttrs (rolloutFeatures != []) {
        # The proprietary binary the rollout patch rewrites. On linux this is
        # the only layer the rename reaches: upstream's FHS wrapper hardcodes
        # `pname = "kiro-cli"` for the shared environment, so its `-bwrap` /
        # `-fhsenv-rootfs` intermediates keep stock names; they carry no
        # proprietary bytes and are inert without this path.
        pname = "kiro-cli-unwrapped-${rolloutSuffix}";
        postInstallCheck = vu.kiroRolloutVerify;
      });
  in
    # Re-wrap through upstream's own expression rather than reimplementing it,
    # so the Linux FHS sandbox (and whatever upstream adds to that wrapper
    # next) comes along for free.
    #
    # `passthru` is NOT a derivation input, so re-attaching ours to the
    # wrapper moves neither `drvPath` nor `outPath`. Merge on top of
    # upstream's rather than replacing it: the Linux wrapper carries
    # `unwrapped` and `tests`.
    (pkgs.kiro-cli.override {
      kiro-cli-unwrapped = pinned;
    }).overrideAttrs
    (joinAttrs:
      {
        # `unwrapped` is re-asserted because darwin's public package is
        # `kiro-cli-unwrapped.overrideAttrs {pname = …;}`, which carries no
        # such attr. Pinning it here makes the route from the public attribute
        # back to the real binary hold on BOTH platforms — load-bearing,
        # because the locator's own failure text tells the reader to check
        # `passthru.unwrapped`.
        passthru =
          (joinAttrs.passthru or {})
          // pinned.passthru
          // {
            unwrapped = pinned;
          };
      }
      # nixpkgs' FHS expression makes one thin wrapper per command it lists,
      # `kiro-cli-chat` and `kiro-cli-term` among them, which 3.0.0 does not
      # ship: they would exec a command the payload lacks. They are created in
      # `extraInstallCommands`, so they are removed there, leaving `bin/` with
      # exactly `kiro-cli` on Linux as on Darwin.
      // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        extraInstallCommands = ''
          ${joinAttrs.extraInstallCommands or ""}
          rm "$out/bin/kiro-cli-chat" "$out/bin/kiro-cli-term"
        '';
      }
      # Expose version for mkKiro.nix, which reads (resolvePackage cfg).version.
      # Conditional, because re-asserting it where present trips nixpkgs'
      # "overridden with `version` but not `src`" lint on the darwin build.
      // pkgs.lib.optionalAttrs (!(joinAttrs ? version)) {
        inherit (sources) version;
      }
      # Rename the EXPORTED package too, so a patched build is identifiable
      # at the attribute consumers install — not only at the unwrapped layer
      # underneath it. Linux's FHS wrapper is renamed through `name`; darwin's
      # `kiro-cli-unwrapped.overrideAttrs {pname = "kiro-cli";}` would
      # otherwise CLOBBER the rename applied to `pinned`. Ours runs last, so
      # it wins.
      // pkgs.lib.optionalAttrs (rolloutFeatures != []) (
        if pkgs.stdenv.hostPlatform.isDarwin
        then {pname = "kiro-cli-${rolloutSuffix}";}
        else {name = "kiro-cli-${rolloutSuffix}-${sources.version}";}
      ));

  mkKiroCli = rawFeatures: mkKiroCliWithPayload rawFeatures {};
in
  mkKiroCli []

# Kiro CLI — override nixpkgs with nightly version.
# Per-platform sources in kiro-cli-sources.json, managed by updateScript.
{
  extractedLib,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchurl makeWrapper;
  inherit (pkgs.stdenv.hostPlatform) system;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  platformSrc = sources.${system} or (throw "kiro-cli: unsupported system ${system}");

  # Derived from the URL rather than branched on the platform, so a future
  # third platform picks up whichever archive form it publishes instead of
  # silently inheriting the linux suffix.
  srcExt =
    if pkgs.lib.hasSuffix ".dmg" platformSrc.url
    then "dmg"
    else "tar.gz";
  # Both selected prompt patches and rollout features follow every public,
  # direct and FHS payload route. The native output binds one selected KAS;
  # KAS depends only on the fetched release input, never on the native output.
  releaseSource = fetchurl {
    inherit (platformSrc) url hash;
    name = "kiro-cli-source-${sources.version}-${system}.${srcExt}";
  };
  mkKas = import ../../../lib/kas.nix {
    inherit pkgs;
    src = releaseSource;
    inherit (basePackage) sourceRoot;
    inherit (sources) version;
  };
  canonFeatures = fs: pkgs.lib.sort (a: b: a < b) (pkgs.lib.unique fs);

  # nixpkgs SPLIT this package (f13ff45a, 2026-08): the real `mkDerivation`
  # moved to `kiro-cli-unwrapped`, and `kiro-cli` became a public FHS wrapper
  # around it — upstream's fix for the TUI extracting a generic-glibc `bun` at
  # runtime, which an FHS root satisfies without patching the extracted asset.
  # It began as a `symlinkJoin` of three per-command environments; 9ddfd8a
  # consolidated them into one environment behind thin command wrappers. The
  # source-owning seam remains `kiro-cli-unwrapped` in both topologies.
  #
  # `overrideAttrs` on that join is a SILENT no-op for everything this overlay
  # exists to do, which is why the base has to be re-pointed rather than the
  # symptom patched:
  #
  #   * `src` / `version` — a `symlinkJoin` has neither, so our nightly pin is
  #     simply dropped and consumers get whatever nixpkgs pinned;
  #   * `postFixup` — stdenv returns from `genericBuild` as soon as it sees a
  #     `buildCommand`, so `fixupPhase` never runs and the TERM default, the
  #     darwin argv0 fix and the rollout patch all evaporate.
  #
  # Measured 2026-08-10 under that pin: `.#kiro-cli` produced upstream's 2.16.1
  # with no wrappers while `kiro-cli-sources.json` said 2.16.2, and the build
  # stayed GREEN. The only symptom anywhere was `passthru.extracted` failing to
  # find a binary — and it misreported that as a hook-trigger vocabulary change.
  #
  # So: override the derivation that HAS a `src`, then hand the result back to
  # upstream's wrapper via `.override`. Every upstream packaging decision is
  # preserved (the FHS sandbox included) and ours are restored on top. The
  # PUBLIC package keeps that upstream-compatible default. Module consumers may
  # explicitly select `passthru.unwrapped` with `useFhsSandbox = false`; that
  # named tradeoff is different from silently changing what `kiro-cli` means.
  #
  # Feature-detected on the ATTRIBUTE, never gated on a nixpkgs version, so one
  # expression is correct on both sides of the split and the branch retires
  # itself when the floor moves past it.
  hasUnwrapped = pkgs ? kiro-cli-unwrapped;
  basePackage =
    if hasUnwrapped
    then pkgs.kiro-cli-unwrapped
    else pkgs.kiro-cli;

  mkKiroCliWithPayload = rawFeatures: bundlePatches: fhsPayload: let
    kas = mkKas bundlePatches;
    managedKas = (bundlePatches.replace or []) != [];
    kasFlags = "${
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
      if builtins.stringLength "${basePackage.pname or "kiro-cli-unwrapped"}-${readableRolloutSuffix}-${sources.version}" < 200
      then readableRolloutSuffix
      else "rollout-${toString (builtins.length rolloutFeatures)}-${builtins.substring 0 12 (builtins.hashString "sha256" (pkgs.lib.concatStringsSep "," rolloutFeatures))}";

    pinned = basePackage.overrideAttrs (finalAttrs: attrs:
      {
        inherit (sources) version;
        # An explicit `name` is the only way these are identifiable in a store
        # or cache listing. The URL basenames carry NO version, and darwin's
        # `Kiro%20CLI.dmg` reaches the store as `Kiro-20CLI.dmg` once nix drops
        # the illegal `%` — so a 647 MiB blob is unattributable to a release.
        #
        # A fixed-output path embeds the NAME, so adopting this moves the src
        # path and therefore every output built from it. That churn is paid
        # ONCE, and the next version bump would have rebuilt them anyway.
        src = releaseSource;

        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [makeWrapper];

        postFixup =
          (attrs.postFixup or "")
          # Darwin's NSBundle dispatch must stay in this package's .app. Passing
          # only an app-shaped argv0 while exec'ing wrapProgram's hidden bin
          # symlink fell back to HOME/.local/bin on 2.29.1 in native CI. Point
          # both the executable filename and argv0 at the actual app binary.
          # Remove only the upstream bin symlink; never move the app binary.
          + (
            if pkgs.stdenv.hostPlatform.isDarwin
            then ''
              test -e "$out/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" || {
                echo "kiro-cli: .app bundle layout moved; darwin argv0 fix needs updating" >&2
                exit 1
              }
              rm "$out/bin/kiro-cli"
              makeWrapper "$out/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" "$out/bin/kiro-cli" \
                --set-default TERM xterm-256color ${kasFlags} \
                --argv0 "$out/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
            ''
            else ''
              wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color ${kasFlags}
            ''
          )
          + ''
            wrapProgram $out/bin/kiro-cli-chat --set-default TERM xterm-256color ${kasFlags}
          ''
          # Deliberately AFTER the wrapProgram calls: the patcher finds the ELF by
          # content, so it is indifferent to how many times wrappers have renamed
          # it, and running last means it sees the final layout instead of
          # guessing at it.
          + pkgs.lib.optionalString (rolloutFeatures != [])
          (vu.mkKiroRolloutPatch {
            features = rolloutFeatures;
            inherit pkgs;
          });

        # Preserve nixpkgs' upstream passthru (repo convention — nix-standards.md) and
        # add ours.
        passthru =
          (attrs.passthru or {})
          // {
            updateScript = vu.mkUpdateScript {
              sourcesFile = repoPath ../../../sources.json;
              pname = "kiro-cli";
              versionCheck.cmd = "${pkgs.curl}/bin/curl -s https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json | ${pkgs.jq}/bin/jq -r '.version'";
              platforms = {
                "aarch64-darwin" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/Kiro%20CLI.dmg";
                "x86_64-linux" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/kirocli-x86_64-linux.tar.gz";
              };
              extraExtract = (extractedLib {inherit pkgs;}).regenCommand {name = "kiro-cli";};
              inherit pkgs;
            };

            # Pure extraction from THIS package's chat binary. IFD-safe:
            # consumed ONLY by `nix build` (drift check + update script), never
            # readFile'd at eval.
            #
            # `finalAttrs.finalPackage` is `pinned` — the derivation that CARRIES
            # the binaries — and never the exported wrapper, whose `$out/bin`
            # holds only sandbox launchers under the split described above.
            # It is a package ROOT, not a file: the chat binary is resolved
            # under it by CONTENT inside the builder, so no wrapper name appears
            # anywhere on this path and the eval-time IFD profile is unchanged.
            extracted = pkgs.runCommandLocal "kiro-cli-extracted.json" {} (
              vu.mkKiroExtract {
                dest = "$out";
                inherit kas pkgs;
                root = "${finalAttrs.finalPackage}";
              }
            );

            inherit kas;
            withBundlePatches = patches: mkKiroCliWithPayload rawFeatures patches null;
            withRolloutFeatures = features: mkKiroCliWithPayload features bundlePatches null;

            # Re-compose the public Linux FHS package around a configured
            # payload without reimplementing nixpkgs' buildFHSEnv expression.
            # The module uses this to place the chat-only trust wrapper INSIDE
            # the synthesized root, where launcher dispatch can actually reach
            # it. Like withRolloutFeatures, the result is unguarded but can only
            # be reached through the guarded public package.
            withFhsPayload = mkKiroCliWithPayload rawFeatures bundlePatches;
          };
      }
      # `optionalAttrs`, NOT an `optionalString` inside an always-present attr.
      # Upstream sets no `postInstallCheck`, so writing `"" + ""` for the default
      # would ADD an attribute it never had. That lands in the build env, forks
      # the drvPath for EVERY consumer including those who never enable a
      # feature, and silently costs the cache hit this option exists to preserve.
      # Measured — it did move the default drvPath before this was corrected.
      #
      // pkgs.lib.optionalAttrs (rolloutFeatures != []) {
        # This is the 621 MiB proprietary ELF — the derivation the rollout
        # patch actually rewrites, and the one whose leak prompted this. It
        # is also the ONLY layer the rename reaches on linux: upstream's
        # wrapper originally hardcoded `pname = executableName` per environment
        # and now hardcodes `pname = "kiro-cli"` for the shared environment,
        # consulting `kiro-cli-unwrapped.pname` nowhere. The `-bwrap` /
        # `-fhsenv-rootfs` intermediates therefore keep stock names for both
        # variants; they carry no proprietary bytes and are inert without this
        # path.
        pname = "${attrs.pname or "kiro-cli-unwrapped"}-${rolloutSuffix}";
        postInstallCheck = (attrs.postInstallCheck or "") + vu.kiroRolloutVerify;
      });
  in
    if hasUnwrapped
    then
      # Re-wrap through upstream's own expression rather than reimplementing it,
      # so the FHS sandbox (and whatever upstream adds to that wrapper next)
      # comes along for free. `fhsPayload` is normally null, which preserves the
      # default pinned payload. The module supplies a wrapped payload only
      # when chat-only configuration must live inside the synthesized root.
      #
      # `passthru` is NOT a derivation input, so re-attaching ours to the join
      # moves neither `drvPath` nor `outPath`. Merge on top of upstream's rather
      # than replacing it: the join carries `unwrapped` and `tests`, and
      # dropping `unwrapped` would take away the only supported route from the
      # public attribute back to the real binaries.
      (pkgs.kiro-cli.override {
        kiro-cli-unwrapped =
          if fhsPayload == null
          then pinned
          else fhsPayload;
      }).overrideAttrs
      (joinAttrs:
        {
          # `unwrapped` is re-asserted rather than merely inherited because
          # `hasUnwrapped` is an ATTRIBUTE-level test and the two platforms
          # compose differently underneath it. On linux upstream's `kiro-cli`
          # is a symlinkJoin whose passthru already carries `unwrapped`; on
          # darwin it is `kiro-cli-unwrapped.overrideAttrs {pname = …;}`, which
          # carries no such attr. Pinning it here makes the route from the
          # public attribute back to the real binaries hold on BOTH platforms —
          # load-bearing, because the locator's own failure text tells the
          # reader to check `passthru.unwrapped`, and advice that resolves to
          # nothing on darwin is worse than no advice.
          passthru =
            (joinAttrs.passthru or {})
            // pinned.passthru
            // {
              # Module validation uses this explicit marker to distinguish an
              # actual FHS wrapper from darwin and pre-split packages that are
              # already direct payloads. A custom package that exposes
              # `unwrapped` without the marker is treated conservatively as an
              # FHS wrapper and must also expose `withFhsPayload` before
              # chat-only configuration is accepted.
              kiroFhsSandbox = pkgs.stdenv.hostPlatform.isLinux;
              unwrapped = pinned;
            };
        }
        # Expose version for mkKiro.nix, which reads (resolvePackage cfg).version.
        #
        # CONDITIONAL on the attr being missing. The original linux
        # `symlinkJoin` omitted `version`; the consolidated FHS derivation and
        # darwin's post-split `kiro-cli` both inherit it. Re-asserting it where
        # present is a no-op that trips nixpkgs' newer
        # "overridden with `version` but not `src`" lint — twice per eval, on
        # the REQUIRED `build (aarch64-darwin, macos-latest)` leg, the moment
        # the nixpkgs bump lands.
        // pkgs.lib.optionalAttrs (!(joinAttrs ? version)) {
          inherit (sources) version;
        }
        # Rename the EXPORTED package too, so a patched build is identifiable
        # at the attribute consumers install — not only at the unwrapped layer
        # underneath it.
        #
        # PLATFORM-BRANCHED because linux's public wrapper is renamed through
        # `name` in both supported topologies (the original `symlinkJoin` and
        # the current shared FHS derivation). On darwin it is
        # `kiro-cli-unwrapped.overrideAttrs {pname = "kiro-cli";}` — whose
        # hardcoded `pname` would otherwise CLOBBER the rename applied to
        # `pinned` above, leaving darwin's 1.22 GiB output indistinguishable.
        # Ours runs last, so it wins.
        // pkgs.lib.optionalAttrs (rolloutFeatures != []) (
          if pkgs.stdenv.hostPlatform.isDarwin
          then {pname = "kiro-cli-${rolloutSuffix}";}
          else {name = "kiro-cli-${rolloutSuffix}-${sources.version}";}
        ))
    # Pre-split nixpkgs: `kiro-cli` IS the derivation carrying the binaries, so
    # there is nothing to re-wrap. Attach the same public package-selection
    # contract without changing the derivation input: opt-out is a no-op here,
    # and the explicit false marker prevents validation from mistaking the
    # direct payload for an FHS wrapper merely because it exposes `unwrapped`.
    else
      pinned.overrideAttrs (attrs: {
        passthru =
          (attrs.passthru or {})
          // {
            kiroFhsSandbox = false;
            unwrapped = pinned;
          };
      });

  mkKiroCli = rawFeatures: mkKiroCliWithPayload rawFeatures {} null;
in
  mkKiroCli []

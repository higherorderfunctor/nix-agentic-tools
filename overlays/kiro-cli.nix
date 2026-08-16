# Kiro CLI — override nixpkgs with nightly version.
# Per-platform sources in kiro-cli-sources.json, managed by updateScript.
#
# Unfree: wrapped by ensureUnfreeCheck in default.nix so the consumer's
# allowUnfree config is respected.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl makeWrapper;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  vu = import ./lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./kiro-cli-sources.json);
  platformSrc = sources.${system} or (throw "kiro-cli: unsupported system ${system}");

  # Derived from the URL rather than branched on the platform, so a future
  # third platform picks up whichever archive form it publishes instead of
  # silently inheriting the linux suffix.
  srcExt =
    if ourPkgs.lib.hasSuffix ".dmg" platformSrc.url
    then "dmg"
    else "tar.gz";
  # Parameterized on the rollout features to unlock, and self-referential via
  # `passthru.withRolloutFeatures`, so a consumer asks for a variant without
  # reaching into the overlay.
  #
  # The DEFAULT (`[]`) must stay byte-identical to the unparameterized
  # derivation this replaced: `optionalString` yields "", `postFixup` is
  # unchanged, the drvPath is unchanged, and `checks.cache-hit-parity` plus
  # every cachix hit keep working. Do NOT "simplify" this by always appending
  # the patch step.
  # Canonicalized HERE rather than at the call site, because this is where
  # derivation identity is decided: the feature list is comma-joined into
  # `postFixup`, so an unsorted or duplicated list yields a different drvPath
  # for a semantically identical set — two redundant ~556 MB builds. Doing it
  # here covers every caller of `withRolloutFeatures`, not just the module.
  # `[]` sorts to `[]`, so the default derivation is untouched.
  canonFeatures = fs: ourPkgs.lib.sort (a: b: a < b) (ourPkgs.lib.unique fs);

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
  hasUnwrapped = ourPkgs ? kiro-cli-unwrapped;
  basePackage =
    if hasUnwrapped
    then ourPkgs.kiro-cli-unwrapped
    else ourPkgs.kiro-cli;

  mkKiroCliWithPayload = rawFeatures: fhsPayload: let
    rolloutFeatures = canonFeatures rawFeatures;

    # Name infix that makes a PATCHED build self-identifying. Both variants
    # were named `kiro-cli-unwrapped-<version>` and differed only by store
    # hash, so a leaked patched binary was indistinguishable from the stock
    # one in a cache listing — which is exactly how one sat unnoticed in the
    # public cache. Derived from the canonicalized feature list, so it names
    # WHICH features were unlocked rather than merely asserting "patched".
    #
    # Consumed only inside `optionalAttrs (rolloutFeatures != [])` blocks:
    # renaming the DEFAULT derivation would fork its drvPath for every
    # consumer and cost the cache hit the `[]` path exists to preserve.
    rolloutSuffix = "rollout-" + ourPkgs.lib.concatStringsSep "-" rolloutFeatures;

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
        src = fetchurl {
          inherit (platformSrc) url hash;
          name = "kiro-cli-source-${sources.version}-${system}.${srcExt}";
        };

        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [makeWrapper];

        postFixup =
          (attrs.postFixup or "")
          # On darwin the launcher locates `kiro-cli-chat` by argv[0]-relative
          # .app BUNDLE DISCOVERY: argv[0]'s parent must literally be
          # `…/Kiro CLI.app/Contents/MacOS`, or it falls back to
          # `$HOME/.local/bin/kiro-cli-chat` — on any Mac that has run the DMG,
          # an UNPATCHED build. PATH is never consulted, and current_exe() is
          # not canonicalized (a symlink to the .app binary still fails —
          # measured). wrapProgram's own `--inherit-argv0` therefore breaks
          # discovery, so on darwin we override argv[0] with the bundle path;
          # makeWrapper documents "whichever comes last of --argv0 and
          # --inherit-argv0 wins", and wrapProgram injects --inherit-argv0
          # BEFORE user args. Measured on hardware 2026-08-04 (2.16.0 store,
          # 2.16.1 DMG): the exec -a "<bundle path>" shape resolves the store's
          # .app sibling and hands KIRO_ENABLED_FEATURES=["workflows","tangent"]
          # to kas/2.16.0. See packages/kiro-cli/docs/launcher-argv.md.
          #
          # The `test -e` is a fail-loud layout guard: argv[0] is just a string
          # (the exec'd file is the hidden wrapped binary), so if the bundle
          # path ever moves, the wrapper would build fine and discovery would
          # silently regress to the DMG fallback again.
          + (
            if ourPkgs.stdenv.hostPlatform.isDarwin
            then ''
              test -e "$out/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli" || {
                echo "kiro-cli: .app bundle layout moved; darwin argv0 fix needs updating" >&2
                exit 1
              }
              wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color \
                --argv0 "$out/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
            ''
            else ''
              wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color
            ''
          )
          + ''
            wrapProgram $out/bin/kiro-cli-chat --set-default TERM xterm-256color
          ''
          # Deliberately AFTER the wrapProgram calls: the patcher finds the ELF by
          # content, so it is indifferent to how many times wrappers have renamed
          # it, and running last means it sees the final layout instead of
          # guessing at it.
          + ourPkgs.lib.optionalString (rolloutFeatures != [])
          (vu.mkKiroRolloutPatch {
            features = rolloutFeatures;
            pkgs = ourPkgs;
          });

        # Preserve nixpkgs' upstream passthru (repo convention — nix-standards.md) and
        # add ours.
        passthru =
          (attrs.passthru or {})
          // {
            updateScript = vu.mkUpdateScript {
              pname = "kiro-cli";
              versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json | ${ourPkgs.jq}/bin/jq -r '.version'";
              platforms = {
                "x86_64-linux" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/kirocli-x86_64-linux.tar.gz";
                "aarch64-darwin" = ver: "https://desktop-release.q.us-east-1.amazonaws.com/${ver}/Kiro%20CLI.dmg";
              };
              # Regenerate the committed hook-trigger sidecar from the freshly-bumped
              # binary in the SAME update/kiro-cli PR (no intra-PR drift), mirroring
              # claude-code.
              extraExtract = vu.mkExtractRegen {
                attr = "kiro-cli";
                dest = "overlays/kiro-cli-extracted.json";
                pkgs = ourPkgs;
              };
              pkgs = ourPkgs;
            };

            # Pure probe of THIS package's own kiro chat binary -> committed-sidecar
            # shape ({hookTriggers, documentedAbsent, rolloutFeatures}). IFD-safe:
            # consumed ONLY by `nix build` (drift check + update script), never
            # readFile'd at eval.
            #
            # `finalAttrs.finalPackage` is `pinned` — the derivation that CARRIES
            # the binaries — and never the exported wrapper, whose `$out/bin`
            # holds only sandbox launchers under the split described above.
            # It is a package ROOT, not a file: the chat binary is resolved
            # under it by CONTENT inside the builder, so no wrapper name appears
            # anywhere on this path and the eval-time IFD profile is unchanged.
            extracted = ourPkgs.runCommandLocal "kiro-cli-extracted.json" {} (
              vu.mkKiroExtract {
                dest = "$out";
                pkgs = ourPkgs;
                root = "${finalAttrs.finalPackage}";
              }
            );

            # Opt-in variant carrying dark-shipped rollout features. Returns an
            # UNGUARDED derivation (no `ensureUnfreeCheck` symlinkJoin), which is
            # sound only because reaching this attribute requires evaluating the
            # guarded `pkgs.ai.kiro-cli` first — check-meta has already fired by
            # then. If this is ever exposed somewhere that does NOT go through the
            # guarded attribute, re-wrap it.
            withRolloutFeatures = mkKiroCli;

            # Re-compose the public Linux FHS package around a configured
            # payload without reimplementing nixpkgs' buildFHSEnv expression.
            # The module uses this to place the chat-only trust wrapper INSIDE
            # the synthesized root, where launcher dispatch can actually reach
            # it. Like withRolloutFeatures, the result is unguarded but can only
            # be reached through the guarded public package.
            withFhsPayload = mkKiroCliWithPayload rawFeatures;
          };
      }
      # `optionalAttrs`, NOT an `optionalString` inside an always-present attr.
      # Upstream sets no `postInstallCheck`, so writing `"" + ""` for the default
      # would ADD an attribute it never had. That lands in the build env, forks
      # the drvPath for EVERY consumer including those who never enable a
      # feature, and silently costs the cache hit this option exists to preserve.
      # Measured — it did move the default drvPath before this was corrected.
      #
      # Worth knowing: neither `checks.cache-hit-parity` nor
      # `module-kiro-rollout-default-is-stock` catches that class of regression,
      # because both compare two evaluations that each already contain the
      # change. Diffing `.#kiro-cli.drvPath` against origin/main is what caught
      # it, and is the check to re-run when touching this attrset.
      // ourPkgs.lib.optionalAttrs (rolloutFeatures != []) {
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
      # byte-identical pinned default. The module supplies a wrapped payload only
      # when chat-only configuration must live inside the synthesized root.
      #
      # `passthru` is NOT a derivation input, so re-attaching ours to the join
      # moves neither `drvPath` nor `outPath`. Merge on top of upstream's rather
      # than replacing it: the join carries `unwrapped` and `tests`, and
      # dropping `unwrapped` would take away the only supported route from the
      # public attribute back to the real binaries.
      (ourPkgs.kiro-cli.override {
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
            // {unwrapped = pinned;};
        }
        # `version` is REQUIRED where it is absent, not decoration:
        # `ensureUnfreeCheck` in overlays/default.nix rebuilds every unfree
        # package as `final.symlinkJoin {inherit (drv) name version; …}`, so a
        # wrapper that does not surface the attr fails the guard outright with
        # `attribute 'version' missing`. Upstream's linux join derives
        # `name = "kiro-cli-${version}"` and stops there.
        #
        # The pre-split overlay satisfied this BY ACCIDENT — its `version`
        # override was one of the attrs the join silently ignored, but it still
        # landed on the attrset the guard reads.
        #
        # CONDITIONAL on the attr being missing. The original linux
        # `symlinkJoin` omitted `version`; the consolidated FHS derivation and
        # darwin's post-split `kiro-cli` both inherit it. Re-asserting it where
        # present is a no-op that trips nixpkgs' newer
        # "overridden with `version` but not `src`" lint — twice per eval, on
        # the REQUIRED `build (aarch64-darwin, macos-latest)` leg, the moment
        # the nixpkgs bump lands.
        // ourPkgs.lib.optionalAttrs (!(joinAttrs ? version)) {
          inherit (sources) version;
        }
        # Rename the EXPORTED package too, so a patched build is identifiable
        # at the attribute consumers install — not only at the unwrapped layer
        # underneath it. `ensureUnfreeCheck` does
        # `symlinkJoin {inherit (drv) name version;}`, so the guard wrapper
        # inherits this for free.
        #
        # PLATFORM-BRANCHED because linux's public wrapper is renamed through
        # `name` in both supported topologies (the original `symlinkJoin` and
        # the current shared FHS derivation). On darwin it is
        # `kiro-cli-unwrapped.overrideAttrs {pname = "kiro-cli";}` — whose
        # hardcoded `pname` would otherwise CLOBBER the rename applied to
        # `pinned` above, leaving darwin's 1.22 GiB output indistinguishable.
        # Ours runs last, so it wins.
        // ourPkgs.lib.optionalAttrs (rolloutFeatures != []) (
          if ourPkgs.stdenv.hostPlatform.isDarwin
          then {pname = "kiro-cli-${rolloutSuffix}";}
          else {name = "kiro-cli-${rolloutSuffix}-${sources.version}";}
        ))
    # Pre-split nixpkgs: `kiro-cli` IS the derivation carrying the binaries, so
    # there is nothing to re-wrap and this is byte-identical to what shipped
    # before the split was accounted for.
    else pinned;

  mkKiroCli = rawFeatures: mkKiroCliWithPayload rawFeatures null;
in
  mkKiroCli []

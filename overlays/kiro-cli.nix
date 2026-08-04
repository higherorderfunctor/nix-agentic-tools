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

  mkKiroCli = rawFeatures: let
    rolloutFeatures = canonFeatures rawFeatures;
  in
    ourPkgs.kiro-cli.overrideAttrs (finalAttrs: attrs:
      {
        inherit (sources) version;
        src = fetchurl {inherit (platformSrc) url hash;};

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
            extracted = ourPkgs.runCommandLocal "kiro-cli-extracted.json" {} (
              vu.mkKiroExtract {
                bin = "${finalAttrs.finalPackage}/bin/.kiro-cli-chat-wrapped";
                pkgs = ourPkgs;
                dest = "$out";
              }
            );

            # Opt-in variant carrying dark-shipped rollout features. Returns an
            # UNGUARDED derivation (no `ensureUnfreeCheck` symlinkJoin), which is
            # sound only because reaching this attribute requires evaluating the
            # guarded `pkgs.ai.kiro-cli` first — check-meta has already fired by
            # then. If this is ever exposed somewhere that does NOT go through the
            # guarded attribute, re-wrap it.
            withRolloutFeatures = mkKiroCli;
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
        postInstallCheck = (attrs.postInstallCheck or "") + vu.kiroRolloutVerify;
      });
in
  mkKiroCli []

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
    ourPkgs.kiro-cli.overrideAttrs (finalAttrs: attrs: {
      inherit (sources) version;
      src = fetchurl {inherit (platformSrc) url hash;};

      nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [makeWrapper];

      postFixup =
        (attrs.postFixup or "")
        + ''
          wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color
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
            # claude-code. Builds the pure passthru.extracted against the just-written
            # sources.json and copies it over the committed path, then formats it
            # through the flake formatter so it matches what checks.formatting checks.
            extraExtract = ''
              echo "kiro-cli: regenerating overlays/kiro-cli-extracted.json"
              extracted=$(${ourPkgs.nix}/bin/nix build --no-link --print-out-paths \
                ".#kiro-cli.passthru.extracted")
              ${ourPkgs.coreutils}/bin/cp "$extracted" overlays/kiro-cli-extracted.json
              ${ourPkgs.coreutils}/bin/chmod 644 overlays/kiro-cli-extracted.json
              ${ourPkgs.nix}/bin/nix fmt -- overlays/kiro-cli-extracted.json
              echo "kiro-cli: wrote overlays/kiro-cli-extracted.json"
            '';
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
    });
in
  mkKiroCli []

# Shared `glab.*` option declarations, imported by BOTH the home-manager
# and the devenv facet.
#
# One copy on purpose. The config-parity rule says a feature configurable
# in HM must be configurable in devenv and vice versa, and the reliable
# way to hold that is a single declaration rather than two that agree
# today. The facets differ only in WHERE the wrapped package is installed,
# which is all their own files do.
#
# ── The settings surface is GENERATED, not curated ──────────────────
# `overlays/generic/glab-extracted.json` is built from glab's own
# `internal/config.KeySchema` (see overlays/generic/glab.nix) and
# committed. Every user-settable, non-list key becomes a typed option
# here, carrying upstream's own description.
#
# Reading a committed sidecar rather than the derivation keeps this
# IFD-free: `builtins.readFile` on a path in the repo costs nothing at
# eval time, where reading it out of `passthru.extracted` would force a
# build during evaluation.
{lib}: let
  inherit (lib) mkOption types;

  credentialsLib = import ../../../lib/credentials.nix {inherit lib;};

  # Key partitioning + env-var mapping live in ONE place, shared with
  # ../lib/mkGlab.nix, which renders the exports these options describe.
  glabSchema = import ../lib/schema.nix {inherit lib;};
  inherit (glabSchema) byName envVarOf secretKeys settingKeys;

  typeFor = k:
    if k.type == "bool"
    then types.nullOr types.bool
    else types.nullOr types.str;

  mkSettingOption = name: let
    k = byName.${name};
  in
    mkOption {
      type = typeFor k;
      default = null;
      description = ''
        ${k.description}

        Mapped to ${envVarOf name}. `null` leaves it unset, so glab falls
        back to its own default${
          if k.default == ""
          then ""
          else " (${k.default})"
        }.
      '';
    };

  mkSecretFor = name:
    credentialsLib.mkSecretOption {
      envVar = envVarOf name;
      inherit (byName.${name}) description;
    };
in {
  options.glab =
    {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Install glab wrapped so that its host URL, token and settings
          are supplied from this configuration at invocation time.
        '';
      };

      package = mkOption {
        type = types.package;
        defaultText = lib.literalExpression "pkgs.generic.glab";
        description = "The glab package to wrap.";
      };

      settings = mkOption {
        type = types.submodule {
          options = builtins.listToAttrs (map (n: {
              name = n;
              value = mkSettingOption n;
            })
            settingKeys);
        };
        default = {};
        description = ''
          Non-secret glab configuration. Every option here is generated
          from glab's own config-key schema, so the set cannot drift from
          the packaged version.

          Note that several of these keys are ones glab MAINTAINS ITSELF
          (their descriptions say "automatically set" — `last_seen_version`
          and the `duo_cli_*` / `orbit_local_*` bookkeeping keys). They are
          settable because upstream marks them settable; pinning one means
          glab can no longer update it.
        '';
      };

      extraSettings = mkOption {
        type = types.attrsOf types.str;
        default = {};
        example = lib.literalExpression ''{ some_new_upstream_key = "value"; }'';
        description = ''
          Escape hatch for config keys newer than the packaged glab's
          schema. Each key is uppercased to form its environment variable,
          which is what glab's own `EnvKeyEquivalence` does for any key
          without an explicit override — so this is exact for new keys and
          WRONG for a key that has an alias. If a key here starts working
          differently after a version bump, it has gained an override and
          belongs in `settings` instead (bump the package: the option is
          generated, so it will appear on its own).
        '';
      };
    }
    // builtins.listToAttrs (map (n: {
        name = n;
        value = mkSecretFor n;
      })
      secretKeys);
}

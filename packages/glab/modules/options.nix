# Shared `glab.*` option declarations, imported by BOTH the home-manager
# and the devenv facet.
#
# One copy on purpose. The config-parity rule says a feature configurable
# in HM must be configurable in devenv and vice versa, and the reliable
# way to hold that is a single declaration rather than two that agree
# today. Facet files own installation and lifecycle lowering: Home Manager can
# synchronize a token through the graphical user's keyring, while devenv
# rejects that user-session lifecycle explicitly.
#
# ── The settings surface is GENERATED, not curated ──────────────────
# `overlays/dev-tools/glab-extracted.json` is built from glab's own
# `internal/config.KeySchema` (see overlays/dev-tools/glab.nix) and
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
          Install glab wrapped so that its host URL, credentials and settings
          are supplied from this configuration. Credentials normally resolve
          at invocation time; `keyringSync.enable` instead persists the token
          through glab's operating-system keyring.
        '';
      };

      package = mkOption {
        type = types.package;
        defaultText = lib.literalExpression "pkgs.ai.devTools.glab";
        description = "The glab package to wrap.";
      };

      configDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/home/alice/.local/state/glab-cli";
        description = ''
          Directory glab keeps its own mutable state in — `config.yml`,
          aliases, update bookkeeping. Exported as `GLAB_CONFIG_DIR`.
          `null` leaves glab on its own default, `~/.config/glab-cli`.

          A LITERAL path. It is shell-quoted into the wrapper, so nothing
          in it expands: no `$VAR`, no `$(…)`, no `~`. Build the path in
          Nix instead, where the values are available anyway —
          `"''${config.home.homeDirectory}/…"` under home-manager, or
          `"''${config.devenv.state}/…"` under devenv.

          An earlier revision made this shell-expandable so the devenv
          facet could say `$DEVENV_STATE/glab-cli`. That was unnecessary:
          `devenv.state` is available at EVAL time, so the default is a
          real path. It also meant a `$(…)` in this value would execute on
          every glab invocation, which is a poor property for an option
          that exists only to name a directory.

          This directory is WRITTEN to. glab owns `config.yml`, and the
          wrapper seeds a `hosts:` entry into it on first run so that
          `glab auth status` can see the configured instance.
        '';
      };

      keyringSync = mkOption {
        type = types.submodule {
          options.enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Copy `glab.token` into glab's operating-system keyring once per
              Home Manager activation, deferred until a graphical Linux user
              session is available.

              The synchronizer reads `file` and `helper` credentials only at
              service runtime and passes the token to glab over standard input.
              It never places the token in the Nix store, command arguments, or
              a persistent environment variable. A Secret Service availability
              probe runs before the token is read, preventing glab's normal
              plaintext-config fallback when no keyring is available.

              This lifecycle is Home Manager-only. The shared declaration stays
              visible under devenv for option-tree parity, but the devenv facet
              rejects enabling it: repository shells may consume a user's
              existing global keyring, but must not own login or graphical
              session services.
            '';
          };
        };
        default = {};
        description = "Home Manager synchronization into glab's OS keyring.";
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

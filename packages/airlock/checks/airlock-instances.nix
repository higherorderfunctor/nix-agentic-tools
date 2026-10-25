# `ai.airlock.instances` (modules/instances.nix): both backends render one
# config for one instance, its secrets reach the launcher as secret files,
# its port is claimed, and airlock's own `check-config` accepts the render.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) fill;
  redact = import ../../../lib/redact {inherit lib;};
  asFile = value: {_redact.asFile = value;};

  claudeToken = redact.file "/run/secrets/airlock-claude-token";
  harnessToken = redact.file "/run/secrets/airlock-harness-token";
  zaiKey = redact.file "/run/secrets/airlock-zai-key";
  # A fixed stateDir, since each backend defaults it under its own root.
  sample = {
    port = 8400;
    stateDir = "/srv/airlock/main";
    settings = {
      clients.harness = {
        grants = ["anthropic" "other-anthropic"];
        token = harnessToken;
      };
      credentials = {
        claude = {
          auth = {
            file = claudeToken;
            type = "oauth_bearer";
          };
          provider = "claude";
        };
        other = {
          auth = {
            file = zaiKey;
            type = "api_key";
          };
          provider = "zai";
        };
        zai = {
          auth = {
            file = zaiKey;
            type = "api_key";
          };
          provider = "zai";
        };
      };
      groups = {
        anthropic = {
          intercept = ["api.anthropic.com"];
          members = {
            claude.models = ["claude-declared"];
            zai.models = ["glm-4.7"];
          };
          primary = "claude";
          protocol = "anthropic";
        };
        # Both Anthropic groups are granted, but only the first owns Claude's
        # CONNECT host. Its repeated ID must not duplicate the picker row.
        other-anthropic = {
          intercept = ["other.invalid"];
          members.other.models = ["claude-declared" "other-only"];
          primary = "other";
          protocol = "anthropic";
        };
        # Neither group below is granted.
        openai = {
          intercept = ["openai.invalid"];
          members.zai.models = ["gpt-ungranted"];
          primary = "zai";
          protocol = "openai";
        };
        ungranted = {
          intercept = ["ungranted.invalid"];
          members.zai.models = ["glm-ungranted"];
          primary = "zai";
          protocol = "anthropic";
        };
      };
      providers = {
        claude.preset = "claude";
        zai.preset = "zai";
      };
    };
  };
  evaluate = backend: ai:
    (
      if backend == "hm"
      then evalHm
      else evalDevenv
    ) {ai = lib.recursiveUpdate {airlock.instances.main = sample;} ai;};
  fileOf = result: result.config.ai.services.airlock-main.files.config;
  hm = fileOf (evaluate "hm" {});
  managed = backend:
    fileOf (evaluate backend {
      airlock.instances.main.settings.credentials.claude.auth = {
        file = lib.mkForce null;
        type = lib.mkForce "oauth_managed";
      };
    });
  managedWithFile = backend:
    fileOf (evaluate backend {
      airlock.instances.main.settings.credentials.claude.auth.type = lib.mkForce "oauth_managed";
    });
  override = backend: fileOf (evaluate backend {airlock.instances.main.settings.providers.zai.endpoints.anthropic = "https://api.z.ai/api/anthropic";});
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);
  thrown = backend: ai: !(builtins.tryEval (builtins.deepSeq (fileOf (evaluate backend ai)).content true)).success;
  packageRefused = backend: ai: !(builtins.tryEval (builtins.deepSeq (toString (builtins.head ((evaluate backend ai).config.home.packages or (evaluate backend ai).config.packages))) true)).success;

  # Each secret's placeholder filled with an absolute dummy path, where the
  # launcher would put the 0600 file it writes.
  checked = pkgs.writeText "airlock-config-roundtrip.json" (fill (lib.mapAttrs (name: _: "/run/airlock-check/${name}") hm.secrets) hm.content);
  checkedManaged = pkgs.writeText "airlock-config-managed.json" (fill (lib.mapAttrs (name: _: "/run/airlock-check/${name}") (managed "hm").secrets) (managed "hm").content);
  checkedManagedWithFile = pkgs.writeText "airlock-config-managed-with-file.json" (fill (lib.mapAttrs (name: _: "/run/airlock-check/${name}") (managedWithFile "hm").secrets) (managedWithFile "hm").content);
  checkedOverride = pkgs.writeText "airlock-config-override.json" (fill (lib.mapAttrs (name: _: "/run/airlock-check/${name}") (override "hm").secrets) (override "hm").content);
in {
  checks =
    {
      airlock-config-roundtrip = pkgs.runCommand "airlock-config-roundtrip" {nativeBuildInputs = [pkgs.ai.generic.airlock];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        airlock check-config --config ${checked}
        airlock check-config --config ${checkedManaged}
        airlock check-config --config ${checkedOverride}
        if airlock check-config --config ${checkedManagedWithFile}; then
          echo "managed OAuth unexpectedly accepted a file" >&2
          exit 1
        fi
        echo "ok — airlock check-config accepts preset, managed-OAuth and explicit-override renders" >"$out"
      '';

      airlock-module-eval = mkTest "airlock-module-eval" (
        lib.all (backend: let
          result = evaluate backend {};
          file = fileOf result;
        in
          file
          == hm
          && managed backend == managed "hm"
          && !(builtins.hasAttr "file" (builtins.fromJSON (managed backend).content).credentials.claude.auth)
          && managedWithFile backend == managedWithFile "hm"
          && builtins.hasAttr "file" (builtins.fromJSON (managedWithFile backend).content).credentials.claude.auth
          && override backend == override "hm"
          && (builtins.fromJSON (override backend).content).providers.zai.endpoints.anthropic == "https://api.z.ai/api/anthropic"
          && file.variable == "AIRLOCK_CONFIG"
          # Tagged as secret files: the launcher writes each to a 0600 file and
          # the config receives its path, never the value.
          && file.secrets
          == {
            AIRLOCK_CLIENTS_HARNESS_TOKEN_FILE = asFile harnessToken;
            AIRLOCK_CREDENTIALS_CLAUDE_AUTH_FILE = asFile claudeToken;
            AIRLOCK_CREDENTIALS_OTHER_AUTH_FILE = asFile zaiKey;
            AIRLOCK_CREDENTIALS_ZAI_AUTH_FILE = asFile zaiKey;
          }
          && (builtins.fromJSON file.content).state_dir == sample.stateDir
          && result.config.ai.claims.port."8400" == ["airlock:airlock-main.ports.main"]
          && failures result == []
          # Another owner's service on the instance's port.
          && failures (evaluate backend {cliproxyapi.instances.main.port = 8400;})
          == [
            "ai.claims.port.8400: claimed by airlock:airlock-main.ports.main and cliproxyapi:cliproxyapi-main.ports.main"
            "ai.claims.proxy-instance.main: claimed by airlock and cliproxyapi"
          ]
          # The instance fixes the listen address, and a token takes a reference.
          && thrown backend {airlock.instances.main.settings.listen = "0.0.0.0:8400";}
          && thrown backend {airlock.instances.main.settings.clients.harness.token = "fake-SECRET-token";})
        ["devenv" "hm"]
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-claude-selection = mkTest "airlock-claude-selection" (
        lib.all (backend: let
          selection = {
            instance = "main";
            clientKey = "harness";
          };
          selected = evaluate backend {
            claude = {
              enable = true;
              proxy = selection;
              jail.enable = true;
            };
          };
          settings = claudeSettings selected;
          noJail = evaluate backend {
            claude = {
              enable = true;
              proxy = selection;
            };
          };
          configOnly = evaluate backend {
            claude = {
              enable = true;
              proxy = selection;
              package = null;
            };
          };
          unknown = evaluate backend {
            claude = {
              enable = true;
              proxy = {
                instance = "main";
                clientKey = "missing";
              };
              jail.enable = true;
            };
          };
          codex = evaluate backend {
            codex = {
              enable = true;
              proxy = selection;
            };
          };
          rootCpa = evaluate backend {
            proxy = {
              url = "http://127.0.0.1:8317";
              key = redact.file "/run/secrets/fake-cpa-client";
            };
            claude = {
              enable = true;
              proxy = selection;
              jail.enable = true;
            };
          };
          inheritedCodex = evaluate backend {
            proxy = selection;
            codex.enable = true;
          };
          disabled = evaluate backend {
            airlock.instances.main.enable = false;
            claude = {
              enable = true;
              proxy = selection;
              jail.enable = true;
            };
          };
          partial = evaluate backend {claude.proxy.clientKey = "harness";};
          pickerConflict = evaluate backend {
            claude = {
              enable = true;
              proxy = selection;
              jail.enable = true;
              native.settings.modelPicker.options = [{model = "consumer-model";}];
            };
          };
          configuredProxy = evaluate backend {
            claude = {
              enable = true;
              proxy = selection;
              jail.enable = true;
              native.settings.env.HTTPS_PROXY = "http://bypass.invalid";
            };
          };
          normalizedNull = evaluate backend {
            claude = {
              enable = true;
              jail.enable = true;
              proxy = selection;
              normalized.proxy = lib.mkForce null;
            };
          };
          normalizedIncomplete = evaluate backend {
            claude = {
              enable = true;
              jail.enable = true;
              proxy = selection;
              normalized.proxy = lib.mkForce {
                owner = "airlock";
                url = "http://127.0.0.1:8400";
              };
            };
          };
          jailExcludesProxy = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                exclude.environment = ["HTTPS_PROXY"];
              };
              proxy = selection;
            };
          };
          jailSetsProxy = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.set-env "HTTPS_PROXY" "http://bypass.invalid")];
              };
              proxy = selection;
            };
          };
          jailUnsetsProxy = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.unset-env "HTTPS_PROXY")];
              };
              proxy = selection;
            };
          };
          jailSetsAlias = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.set-env "no_proxy" "*")];
              };
              proxy = selection;
            };
          };
          jailDeferredSetsProxy = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.defer (c.set-env "HTTPS_PROXY" "http://bypass.invalid"))];
              };
              proxy = selection;
            };
          };
          jailDeferredUnsetsProxy = {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.defer (c.unset-env "HTTPS_PROXY"))];
              };
              proxy = selection;
            };
          };
          jailSetsUnrelated = evaluate backend {
            claude = {
              enable = true;
              jail = {
                enable = true;
                permissions = c: [(c.set-env "AIRLOCK_TEST_UNRELATED" "kept")];
              };
              proxy = selection;
            };
          };
        in
          selected.config.ai.claude.normalized.proxy.owner
          == "airlock"
          && selected.config.ai.claude.normalized.proxy.client == "harness"
          && settings.env.ANTHROPIC_BASE_URL == ""
          && settings.env.CLAUDE_CODE_OAUTH_TOKEN == "airlock-fake-oauth-token-not-a-credential"
          && settings.apiKeyHelper == ""
          && selected.config.ai.claude.normalized.proxy.credentials
          == [
            {
              models = ["claude-declared"];
              name = "claude";
            }
            {
              models = ["glm-4.7"];
              name = "zai";
            }
          ]
          && (
            if backend == "hm"
            then
              (claudeSettings selected).modelPicker.options
              == [
                {
                  description = "claude through airlock";
                  model = "claude-declared";
                }
                {
                  description = "zai through airlock";
                  model = "glm-4.7";
                }
              ]
              && (claudeSettings pickerConflict).modelPicker.options
              == [
                {model = "consumer-model";}
                {
                  description = "claude through airlock";
                  model = "claude-declared";
                }
                {
                  description = "zai through airlock";
                  model = "glm-4.7";
                }
              ]
            else
              !(settings ? modelPicker)
              && (claudeSettings pickerConflict).modelPicker.options
              == [{model = "consumer-model";}]
          )
          && lib.hasInfix "claude-jail" (toString (builtins.head (selected.config.home.packages or selected.config.packages)))
          && failures selected == []
          && builtins.any (lib.hasInfix "enable ai.claude.jail") (failures noJail)
          && builtins.any (lib.hasInfix "no managed airlock launcher") configOnly.config.warnings
          && builtins.any (lib.hasInfix "not an `ai.airlock.instances.main.settings.clients` entry") (failures unknown)
          && rootCpa.config.ai.claude.normalized.proxy.owner == "airlock"
          && builtins.any (lib.hasInfix "only Claude supports") (failures codex)
          && builtins.any (lib.hasInfix "only Claude supports") (failures inheritedCodex)
          && builtins.any (lib.hasInfix "which is disabled") (failures disabled)
          && builtins.any (lib.hasInfix "is set without `instance`") (failures partial)
          && builtins.any (lib.hasInfix "native.settings.env must not set proxy variables") (failures configuredProxy)
          && normalizedNull.config.ai.claude.normalized.proxy == null
          && !(builtins.hasAttr "apiKeyHelper" (claudeSettings normalizedNull))
          && failures normalizedNull == []
          && builtins.any (lib.hasInfix "needs client, instance and port") (failures normalizedIncomplete)
          && packageRefused backend jailExcludesProxy
          && packageRefused backend jailSetsProxy
          && packageRefused backend jailUnsetsProxy
          && packageRefused backend jailSetsAlias
          && packageRefused backend jailDeferredSetsProxy
          && packageRefused backend jailDeferredUnsetsProxy
          && builtins.isString (toString (builtins.head (jailSetsUnrelated.config.home.packages or jailSetsUnrelated.config.packages))))
        ["devenv" "hm"]
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Darwin has no bubblewrap, so a selected Claude warns and gets no launcher.
      airlock-claude-darwin-warns = mkTest "airlock-claude-darwin-warns" (
        lib.all (backend: let
          result = evaluate backend {
            claude = {
              enable = true;
              jail.enable = true;
              proxy = {
                instance = "main";
                clientKey = "harness";
              };
            };
          };
        in
          builtins.any (lib.hasInfix "bubblewrap is Linux-only; no airlock launcher is delivered") result.config.warnings
          && (result.config.home.packages or result.config.packages) == [])
        ["devenv" "hm"]
      );
    };
}

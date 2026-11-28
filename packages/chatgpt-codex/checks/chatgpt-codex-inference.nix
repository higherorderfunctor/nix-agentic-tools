# `ai.settings.inference` for Codex: both backends use the shared redact reader through
# command-backed provider auth, and the selected provider wins across layers.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  keyFile = "/tmp/codex-proxy $(touch injected) ' key";
  command = lib.getExe (import ../../../lib/strict-shell-application.nix pkgs {
    name = "codex-proxy-test-command";
    text = ''
      printf '%s' "$CODEX_PROXY_TEST_VALUE"
      exit "$CODEX_PROXY_TEST_STATUS"
    '';
  });
  keys = {
    command = redact.command command;
    concat = redact.concat ["prefix-\"'$HOME$(touch injected)`" (redact.file keyFile) "-suffix"];
    file = redact.file keyFile;
  };
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  hmOrigin = "http://127.0.0.1:8317";
  devenvOrigin = "http://127.0.0.1:8318";
  failedMessages = result: map (a: a.message) (builtins.filter (a: !a.assertion) result.config.assertions);
  hmSettings = result: result.config.ai.codex.files.".codex/config.toml".content.value;
  hmWith = proxy:
    evalHm {
      ai = {
        codex.enable = true;
        settings.inference = proxy;
      };
    };
  hmEndpoint = key:
    hmWith {
      url = hmOrigin;
      inherit key;
    };
  deliveredHmConfig = result: result.config.home.file.".codex/config.toml".source;
  hmOverride = evalHm {
    ai = {
      codex = {
        enable = true;
        settings.inference = {
          url = devenvOrigin;
          key = keys.command;
        };
      };
      settings.inference = {
        url = hmOrigin;
        key = keys.file;
      };
    };
  };
  devenvWith = ai:
    evalDevenv {
      ai = lib.recursiveUpdate {codex.enable = true;} ai;
    };
  launcher = key: "${lib.head
    (devenvWith {
      settings.inference = {
        url = devenvOrigin;
        inherit key;
      };
    }).config.packages}/bin/codex";
in {
  checks =
    {
      module-codex-inference-availability-nux = mkTest "codex-inference-availability-nux" (
        lib.all (
          backend: let
            eval = backends.${backend};
            evaluate = settings: proxy:
              eval {
                ai = {
                  codex = {
                    enable = true;
                    native.settings = settings;
                  };
                  settings.inference = proxy;
                };
              };
            proxy = {
              url = hmOrigin;
              key = keys.file;
            };
            selected = evaluate {} proxy;
            unselected = evaluate {} {};
            overridden = evaluate {tui.model_availability_nux."gpt-6.1-sol" = 0;} proxy;
          in
            checkRows "Codex availability tooltip (${backend})" {
              "consumer count does not override the proxy default" = overridden.config.ai.codex.native.settings.tui.model_availability_nux."gpt-6.1-sol" == 0;
              "proxy count leaks into an unselected runtime" = !(unselected.config.ai.codex.native.settings.tui or {} ? model_availability_nux);
              "selected proxy leaves the availability tooltip enabled" = selected.config.ai.codex.native.settings.tui.model_availability_nux."gpt-6.1-sol" == 4;
            }
        ) (builtins.attrNames backends)
      );

      # Project config cannot carry providers. The launcher supplies them as
      # session flags; only the availability tooltip default reaches project config.
      module-codex-inference-devenv-project-config = mkTest "codex-inference-devenv-project-config" (
        let
          url = devenvWith {
            settings.inference = {
              url = devenvOrigin;
              key = keys.file;
            };
          };
          unmanaged = devenvWith {
            codex.package = null;
            settings.inference = {
              url = devenvOrigin;
              key = keys.file;
            };
          };
        in
          checkRows "devenv Codex inference" {
            "a no-package launcher silently drops the selected provider" =
              builtins.any (lib.hasPrefix "ai.codex.settings.inference is selected but ai.codex.package is null") unmanaged.config.warnings;
            "a selected provider causes a module assertion" = failedMessages url == [];
          }
      );

      module-codex-inference-hm-provider = mkTest "codex-inference-hm-provider" (
        let
          file = hmEndpoint keys.file;
          settings = hmSettings file;
          provider = settings.model_providers.ai-inference;
          userBase = evalHm {
            ai = {
              codex = {
                enable = true;
                native.settings.model_providers.ai-inference.base_url = "http://127.0.0.1:9999/v1";
              };
              settings.inference = {
                url = hmOrigin;
                key = keys.file;
              };
            };
          };
        in
          checkRows "Home Manager Codex inference" ({
              "a selected provider causes a module assertion" = failedMessages file == [];
              "file uses inline auth or a PATH-dependent helper" =
                builtins.attrNames provider.auth == ["command"] && lib.hasPrefix "/" provider.auth.command;
              "the generated provider uses the wrong protocol, endpoint, or built-in auth" =
                builtins.removeAttrs provider ["auth"]
                == {
                  base_url = "http://127.0.0.1:8317/v1";
                  name = "ai-inference";
                  requires_openai_auth = false;
                  wire_api = "responses";
                };
              "the proxy provider is not selected or another provider is generated" =
                settings.model_provider
                == "ai-inference"
                && builtins.attrNames settings.model_providers == ["ai-inference"];
              "unselected inference sets a provider" = !((hmSettings (hmWith {})) ? model_provider);
              "user base URL is ignored or overriding it erases the rest of the provider" =
                (hmSettings userBase).model_providers.ai-inference.base_url
                == "http://127.0.0.1:9999/v1"
                && (hmSettings userBase).model_providers.ai-inference.wire_api == "responses";
            }
            # Linux checks this selection through real Codex requests below.
            // lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isLinux) {
              "shared inference overrides the Home Manager runtime selection" =
                (hmSettings hmOverride).model_providers.ai-inference.base_url == "http://127.0.0.1:8318/v1";
            })
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      chatgpt-codex-inference =
        pkgs.runCommand "chatgpt-codex-inference" {
          nativeBuildInputs = [pkgs.coreutils pkgs.python3];
          cases = pkgs.writeText "codex-proxy-cases.json" (builtins.toJSON {
            configs = lib.mapAttrs (_: key: deliveredHmConfig (hmEndpoint key)) keys;
            hmOverride = deliveredHmConfig hmOverride;
            launchers = lib.mapAttrs (_: launcher) keys;
          });
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 ${./inference-test.py} ${lib.escapeShellArgs [
            "${harness.aiStubs.chatgpt-codex}/bin/codex"
            keyFile
          ]} "$cases"
          echo PASS >"$out"
        '';
    };
}

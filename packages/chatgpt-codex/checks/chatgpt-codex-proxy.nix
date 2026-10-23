# `ai.proxy` for Codex: both backends use the shared redact reader through
# command-backed provider auth, and the selected provider wins across layers.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
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
  hmOrigin = "http://127.0.0.1:8317";
  devenvOrigin = "http://127.0.0.1:8318";
  failedMessages = result: map (a: a.message) (builtins.filter (a: !a.assertion) result.config.assertions);
  hmSettings = result: result.config.ai.codex.files.".codex/config.toml".content.value;
  hmWith = proxy:
    evalHm {
      ai = {
        codex.enable = true;
        inherit proxy;
      };
    };
  hmEndpoint = key:
    hmWith {
      url = hmOrigin;
      inherit key;
    };
  hmConfig = key: (hmEndpoint key).config.home.file.".codex/config.toml".source;
  devenvWith = ai:
    evalDevenv {
      ai = lib.recursiveUpdate {codex.enable = true;} ai;
    };
  launcher = key: "${lib.head
    (devenvWith {
      proxy = {
        url = devenvOrigin;
        inherit key;
      };
    }).config.packages}/bin/codex";
  unsupportedWarning = backend: lib.hasPrefix "ai.proxy is set but ${backend} does not deliver it to codex";
in {
  checks =
    {
      module-codex-proxy-availability-nux = mkTest "codex-proxy-availability-nux" (
        lib.all (
          eval: let
            evaluate = settings: proxy:
              eval {
                ai = {
                  codex = {
                    enable = true;
                    native.settings = settings;
                  };
                  inherit proxy;
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
            selected.config.ai.codex.native.settings.tui.model_availability_nux."gpt-6.1-sol"
            == 4
            && !(unselected.config.ai.codex.native.settings.tui or {} ? model_availability_nux)
            && overridden.config.ai.codex.native.settings.tui.model_availability_nux."gpt-6.1-sol" == 0
        ) [evalDevenv evalHm]
      );

      # Project config cannot carry providers. The launcher supplies them as
      # session flags; only the availability tooltip default reaches project config.
      module-codex-proxy-devenv-project-config = mkTest "codex-proxy-devenv-project-config" (
        let
          url = devenvWith {
            proxy = {
              url = devenvOrigin;
              key = keys.file;
            };
          };
          none = devenvWith {};
          unmanaged = devenvWith {
            codex.package = null;
            proxy = {
              url = devenvOrigin;
              key = keys.file;
            };
          };
        in
          failedMessages url
          == []
          && builtins.any (lib.hasPrefix "ai.codex.proxy is selected but ai.codex.package is null") unmanaged.config.warnings
          && !(builtins.any (lib.hasPrefix "ai.codex.proxy is selected") url.config.warnings)
          && !(url.config.ai.codex.files.".codex/config.toml".content.value ? model_provider)
          && !(url.config.ai.codex.files.".codex/config.toml".content.value ? model_providers)
          && !(none.config.ai.codex.files ? ".codex/config.toml")
          && !(builtins.any (unsupportedWarning "devenv") url.config.warnings)
      );

      module-codex-proxy-hm-provider = mkTest "codex-proxy-hm-provider" (
        let
          file = hmEndpoint keys.file;
          provider = (hmSettings file).model_providers.ai-proxy;
          overridden = evalHm {
            ai = {
              codex = {
                enable = true;
                proxy = {
                  url = devenvOrigin;
                  key = keys.command;
                };
              };
              proxy = {
                url = hmOrigin;
                key = keys.file;
              };
            };
          };
        in
          failedMessages file
          == []
          && lib.filterAttrs (name: _: builtins.elem name ["model_provider" "model_providers"]) (hmSettings file)
          == {
            model_provider = "ai-proxy";
            model_providers.ai-proxy = {
              auth.command = provider.auth.command;
              base_url = "${hmOrigin}/v1";
              name = "ai-proxy";
              requires_openai_auth = false;
              wire_api = "responses";
            };
          }
          && lib.all (key: let
            auth = (hmSettings (hmEndpoint key)).model_providers.ai-proxy.auth;
          in
            builtins.attrNames auth == ["command"] && lib.hasSuffix "/bin/cpa-client-key" auth.command) (builtins.attrValues keys)
          && (hmSettings overridden).model_providers.ai-proxy.base_url == "${devenvOrigin}/v1"
          && (hmSettings overridden).model_providers.ai-proxy.auth == (hmSettings (hmEndpoint keys.command)).model_providers.ai-proxy.auth
          && !(builtins.any (unsupportedWarning "hm") file.config.warnings)
          && !((hmSettings (hmWith {})) ? model_provider)
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      chatgpt-codex-proxy =
        pkgs.runCommand "chatgpt-codex-proxy" {
          nativeBuildInputs = [pkgs.coreutils pkgs.python3];
          cases = pkgs.writeText "codex-proxy-cases.json" (builtins.toJSON {
            configs = lib.mapAttrs (_: hmConfig) keys;
            launchers = lib.mapAttrs (_: launcher) keys;
          });
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 ${./proxy-test.py} ${lib.escapeShellArgs [
            "${harness.aiStubs.chatgpt-codex}/bin/codex"
            keyFile
          ]} "$cases"
          echo PASS >"$out"
        '';
    };
}

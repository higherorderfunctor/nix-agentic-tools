# `ai.proxy` for Codex (lib/proxy.nix): the provider Home Manager writes into
# user config.toml, the session flags devenv's launcher passes, and, against
# the pinned binary and loopback mock proxies, that every request reaches the
# selected proxy with the selected key in each key form and backend
# combination.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;

  # Rewritten to the build directory by the runtime check; a /run/secrets
  # path would not exist in the sandbox.
  secretsPlaceholder = "/nat-codex-proxy-secrets";
  helper = pkgs.writeShellScript "codex-proxy-key-helper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    echo sk-hm-helper
  '';
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
  launcher = result: "${lib.head result.config.packages}/bin/codex";

  fileProvider = {
    auth = {
      args = ["${secretsPlaceholder}/hm-key"];
      command = "${pkgs.coreutils}/bin/cat";
    };
    base_url = "${hmOrigin}/v1";
    name = "ai-proxy";
    requires_openai_auth = false;
    wire_api = "responses";
  };
  unsupportedWarning = backend: lib.hasPrefix "ai.proxy is set but ${backend} does not deliver it to codex";
in {
  checks =
    {
      # The provider, its key form and the overridable quieting defaults in
      # user config.toml; a declared instance resolves to its registry entry,
      # an undeclared one fails; `ai.codex.proxy` replaces the root selection;
      # and Codex no longer warns that it ignores the surface.
      module-codex-proxy-hm-provider = mkTest "codex-proxy-hm-provider" (
        let
          file = hmEndpoint {file = "${secretsPlaceholder}/hm-key";};
          instance = evalHm {
            ai = {
              codex.enable = true;
              proxy = {
                instance = "main";
                instances.main = {
                  clientKey.helper = "${helper}";
                  port = 8319;
                };
              };
            };
          };
          overridden = evalHm {
            ai = {
              codex = {
                enable = true;
                native.settings.analytics.enabled = true;
                proxy = {
                  url = devenvOrigin;
                  key.plain = "sk-codex";
                };
              };
              proxy = {
                url = hmOrigin;
                key.plain = "sk-root";
              };
            };
          };
        in
          failedMessages file
          == []
          && lib.filterAttrs (name: _: builtins.elem name ["analytics" "features" "model_provider" "model_providers"]) (hmSettings file)
          == {
            analytics.enabled = false;
            features = {
              daemon_auto_start = false;
              plugins = false;
            };
            model_provider = "ai-proxy";
            model_providers.ai-proxy = fileProvider;
          }
          && (hmSettings (hmEndpoint {plain = "sk-hm-plain";})).model_providers.ai-proxy.experimental_bearer_token == "sk-hm-plain"
          && (hmSettings instance).model_providers.ai-proxy
          == {
            auth.command = "${helper}";
            base_url = "http://127.0.0.1:8319/v1";
            name = "ai-proxy";
            requires_openai_auth = false;
            wire_api = "responses";
          }
          && builtins.any (message: lib.hasInfix "instance \"work\"" message && lib.hasInfix "does not declare in ai.proxy.instances" message) (failedMessages (hmWith {instance = "work";}))
          && (hmSettings overridden).model_providers.ai-proxy.experimental_bearer_token == "sk-codex"
          && (hmSettings overridden).analytics.enabled
          && !(builtins.any (unsupportedWarning "hm") file.config.warnings)
          && !((hmSettings (hmWith {})) ? model_provider)
      );

      # devenv writes no provider into the project config, which Codex would
      # ignore (the launcher carries it; chatgpt-codex-proxy runs it); the
      # quieting defaults do go there, and only with a selection.
      module-codex-proxy-devenv-project-config = mkTest "codex-proxy-devenv-project-config" (
        let
          url = devenvWith {
            proxy = {
              url = devenvOrigin;
              key.plain = "sk-devenv-url";
            };
          };
          none = devenvWith {};
          project = result: result.config.ai.codex.files.".codex/config.toml".content.value;
        in
          failedMessages url
          == []
          && project url
          == {
            analytics.enabled = false;
            features.plugins = false;
          }
          && !(none.config.ai.codex.files ? ".codex/config.toml")
          && !(builtins.any (unsupportedWarning "devenv") url.config.warnings)
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      chatgpt-codex-proxy =
        pkgs.runCommand "chatgpt-codex-proxy" {
          nativeBuildInputs = [pkgs.coreutils pkgs.python3];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 ${./proxy-test.py} ${lib.escapeShellArgs [
            "${harness.aiStubs.chatgpt-codex}/bin/codex"
            (hmConfig {plain = "sk-hm-plain";})
            (hmConfig {file = "${secretsPlaceholder}/hm-key";})
            (hmConfig {helper = "${helper}";})
            (launcher (devenvWith {
              proxy = {
                url = devenvOrigin;
                key.plain = "sk-devenv-url";
              };
            }))
            (launcher (devenvWith {proxy.instance = "work";}))
            secretsPlaceholder
          ]}
          echo PASS >"$out"
        '';
    };
}

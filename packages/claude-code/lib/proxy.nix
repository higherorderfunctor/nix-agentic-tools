# `ai.proxy` → Claude Code: point Claude at the selected proxy through its
# settings files and, where a lowering needs it, launcher flags.
#
# The resolved endpoint (see lib/ai/proxy/default.nix) runs the lowering of its
# backend, which alone decides what Claude gets: `settings` land in
# `native.settings` at default priority, so the settings.json each backend
# already writes (user on Home Manager, project on devenv) carries them and a
# consumer's own value for a leaf wins; optional `launcherFlags` reach the
# managed launcher.
#
# CLIProxyAPI's lowering turns each routed upstream credential's models into
# `/model` picker rows; where each backend delivers them, and why, is in
# dev/fragments/ai-proxy/ai-proxy-runtimes.md.
{
  lib,
  pkgs,
}: let
  keyHelper = import ../../../lib/ai/proxy/key-helper.nix {inherit lib pkgs;};
  proxyLib = import ../../../lib/ai/proxy {inherit lib;};
  # Each lowering takes the module backend (`hm` or `devenv`), then the
  # resolved proxy.
  lowerings.cliproxyapi = backend: {
    credentials,
    key,
    url,
    ...
  }: let
    helper = keyHelper {
      inherit key;
      option = "ai.claude.proxy.key";
    };
    # One row per model of each routed upstream credential, in route order.
    # Claude labels a row with its model id when it has no label.
    rows = lib.concatMap (credential:
      map (model: {
        description = "${credential.name} through CLIProxyAPI";
        inherit model;
      })
      credential.models)
    credentials;
    # toFile: the rows hold no store paths, and evaluation can read it back.
    picker = builtins.toFile "claude-proxy-model-picker.json" (builtins.toJSON {modelPicker.options = rows;});
  in {
    # Claude reads and caches this descriptor before applying settings env.
    # A settings-only blank therefore still leaks its key to the proxy.
    # devenv's picker rows travel as `--settings`, the one non-user scope a
    # project can reach; they replace any user `modelPicker` in that session,
    # since the highest scope that defines it wins outright.
    launcherFlags =
      ["--unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"]
      ++ lib.optional (backend == "devenv" && rows != []) "--add-flags ${lib.escapeShellArg "--settings ${picker}"}";
    # Settings env overrides inherited API keys, bearer tokens and custom
    # headers, so a lower-scope credential cannot accompany the reference
    # resolved by apiKeyHelper, and inherited Bedrock, Vertex or Foundry
    # switches, which would send model traffic past the proxy. Without a
    # proxy, nonessential traffic and the autoupdater reach api.anthropic.com
    # and downloads.claude.ai directly; the quiet defaults stop both.
    settings =
      {
        apiKeyHelper = lib.escapeShellArg (lib.getExe helper);
        disableClaudeAiConnectors = true;
        env = {
          ANTHROPIC_API_KEY = "";
          ANTHROPIC_AUTH_TOKEN = "";
          ANTHROPIC_BASE_URL = url;
          ANTHROPIC_CUSTOM_HEADERS = "";
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
          CLAUDE_CODE_USE_BEDROCK = "";
          CLAUDE_CODE_USE_FOUNDRY = "";
          CLAUDE_CODE_USE_VERTEX = "";
          DISABLE_AUTOUPDATER = "1";
        };
      }
      // lib.optionalAttrs (backend == "hm" && rows != []) {modelPicker.options = rows;};
  };

  forLowerings = lowerings: let
    # `{}` when nothing is selected.
    lower = backend: resolvedProxy:
      lib.optionalAttrs (resolvedProxy != null)
      (proxyLib.lower "claude" (lib.mapAttrs (_: lowering: lowering backend) lowerings) resolvedProxy);
    launcherFlags = {
      backend,
      resolvedProxy,
    }:
      (lower backend resolvedProxy).launcherFlags or [];
  in {
    inherit launcherFlags;
    installPackage = {
      backend,
      cfg,
      resolvedProxy,
      ...
    }:
      lib.ai.mkLauncher pkgs {
        exe = "claude";
        flags = launcherFlags {inherit backend resolvedProxy;};
        name = "claude-code-proxy";
        inherit (cfg) package;
      };

    config = {
      backend,
      resolvedProxy,
    }:
      lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings = lib.mapAttrsRecursive (_: lib.mkDefault) ((lower backend resolvedProxy).settings or {});
      };
  };
in
  forLowerings lowerings
  // {
    # Checks give a test-only backend its own lowering beside CLIProxyAPI's.
    withLowerings = extra: forLowerings (lowerings // extra);
  }

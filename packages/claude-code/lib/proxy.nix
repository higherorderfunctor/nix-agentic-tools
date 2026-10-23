# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files. Its launcher suppresses the inherited API-key descriptor
# before Claude caches it, ahead of applying settings env.
#
# The resolved endpoint (see lib/ai/proxy/default.nix) lands in
# `native.settings`, so the settings.json each backend already writes (user on
# Home Manager, project on devenv).
#
# Each routed upstream credential's models become `/model` picker rows; where each
# backend delivers them, and why, is in dev/fragments/ai-proxy/ai-proxy-runtimes.md.
{
  lib,
  pkgs,
}: let
  keyHelper = import ../../../lib/ai/proxy/key-helper.nix {inherit lib pkgs;};
  # Settings env overrides inherited API keys, bearer tokens and custom
  # headers, so a lower-scope credential cannot accompany the reference
  # resolved by apiKeyHelper, and inherited Bedrock, Vertex or Foundry
  # switches, which would send model traffic past the proxy.
  render = {
    key,
    url,
    ...
  }: let
    helper = keyHelper {
      inherit key;
      option = "ai.claude.proxy.key";
    };
  in {
    apiKeyHelper = lib.escapeShellArg (lib.getExe helper);
    env = {
      ANTHROPIC_API_KEY = "";
      ANTHROPIC_AUTH_TOKEN = "";
      ANTHROPIC_BASE_URL = url;
      ANTHROPIC_CUSTOM_HEADERS = "";
      CLAUDE_CODE_USE_BEDROCK = "";
      CLAUDE_CODE_USE_FOUNDRY = "";
      CLAUDE_CODE_USE_VERTEX = "";
    };
  };

  # One row per model of each routed upstream credential, in route order. Claude
  # labels a row with its model id when it has no label.
  pickerRows = resolvedProxy:
    lib.concatMap (credential:
      map (model: {
        description = "${credential.name} through CLIProxyAPI";
        inherit model;
      })
      credential.models)
    (
      if resolvedProxy == null
      then []
      else resolvedProxy.credentials
    );

  # Without a proxy these reach api.anthropic.com and downloads.claude.ai
  # directly. Defaults, so a consumer can turn either back on.
  quietEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
  };
in {
  # Claude reads and caches this descriptor before applying settings env.
  # A settings-only blank therefore still leaks its key to the selected proxy.
  # devenv's picker rows travel as `--settings`, the one non-user scope a
  # project can reach; they replace any user `modelPicker` in that session,
  # since the highest scope that defines it wins outright.
  installPackage = {
    backend,
    cfg,
    resolvedProxy,
    ...
  }: let
    rows = pickerRows resolvedProxy;
    # toFile: the rows hold no store paths, and evaluation can read it back.
    picker = builtins.toFile "claude-proxy-model-picker.json" (builtins.toJSON {modelPicker.options = rows;});
  in
    lib.ai.mkLauncher pkgs {
      exe = "claude";
      flags =
        lib.optional (resolvedProxy != null) "--unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
        ++ lib.optional (backend == "devenv" && rows != []) "--add-flags ${lib.escapeShellArg "--settings ${picker}"}";
      name = "claude-code-proxy";
      inherit (cfg) package;
    };

  config = {
    backend,
    resolvedProxy,
  }:
    lib.mkMerge [
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings = {
          disableClaudeAiConnectors = lib.mkDefault true;
          env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
        };
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings = render resolvedProxy;
      })
      (lib.mkIf (backend == "hm" && pickerRows resolvedProxy != []) {
        ai.claude.native.settings.modelPicker.options = pickerRows resolvedProxy;
      })
    ];
}

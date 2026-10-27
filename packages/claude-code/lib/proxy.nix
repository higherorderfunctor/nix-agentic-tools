# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files. Its launcher suppresses the inherited API-key descriptor
# before Claude caches it, ahead of applying settings env. An Airlock selection
# instead adds a launcher `--run` snippet that exports HTTPS_PROXY and trust
# from the running instance, and leaves native settings alone.
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
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  isAirlock = proxy: (proxy.owner or null) == "airlock";
  isCpa = proxy: proxy != null && !isAirlock proxy;
  proxyEnvironment = ["ALL_PROXY" "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY" "all_proxy" "http_proxy" "https_proxy" "no_proxy"];
  nativeEnvironment = cfg:
    if (cfg.native.settings.env or null) == null
    then {}
    else cfg.native.settings.env;
  airlockFlags = config: cfg: proxy: let
    service = "airlock-${proxy.instance}";
    # Claude applies settings env after exec. Apply just its runtime-directory
    # inputs before lookup, then let the service's own literal overrides win.
    directories = lib.intersectAttrs {
      TMPDIR = null;
      XDG_RUNTIME_DIR = null;
    } (nativeEnvironment cfg);
    snippet = ''
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") directories)}
      ${services.runtimeDirectoryPath pkgs service config.ai.services.${service}}
      _airlock_exports="$(${pkgs.python3}/bin/python3 ${../../airlock/lib/client-environment.py} "$_ai_dir" ${lib.escapeShellArg proxy.client} ${toString proxy.port})"
      unset ${lib.concatStringsSep " " proxyEnvironment}
      eval "$_airlock_exports"
      unset _airlock_exports _ai_dir _ai_runtime_xdg _ai_runtime_tmp
    '';
  in ["--run ${lib.escapeShellArg snippet}"];
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
  inherit isAirlock isCpa;
  conflicts = config: cfg: proxy: let
    interception = config.ai.airlock.instances.${proxy.instance}.settings.interception != null;
    managed = proxyEnvironment ++ lib.optionals interception ["NODE_EXTRA_CA_CERTS" "NODE_TLS_REJECT_UNAUTHORIZED"];
  in
    lib.intersectLists managed (builtins.attrNames (nativeEnvironment cfg));
  # Claude reads and caches this descriptor before applying settings env.
  # A settings-only blank therefore still leaks its key to the selected proxy.
  # devenv's picker rows travel as `--settings`, the one non-user scope a
  # project can reach; they replace any user `modelPicker` in that session,
  # since the highest scope that defines it wins outright.
  installPackage = {
    backend,
    cfg,
    config,
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
        lib.optionals (isAirlock resolvedProxy) (airlockFlags config cfg resolvedProxy)
        ++ lib.optional (isCpa resolvedProxy) "--unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
        ++ lib.optional (backend == "devenv" && rows != []) "--add-flags ${lib.escapeShellArg "--settings ${picker}"}";
      name = "claude-code-proxy";
      inherit (cfg) package;
    };

  config = {
    backend,
    resolvedProxy,
  }:
    lib.mkMerge [
      (lib.mkIf (isCpa resolvedProxy) {
        ai.claude.native.settings = {
          disableClaudeAiConnectors = lib.mkDefault true;
          env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
        };
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (isCpa resolvedProxy) {
        ai.claude.native.settings = render resolvedProxy;
      })
      (lib.mkIf (backend == "hm" && pickerRows resolvedProxy != []) {
        ai.claude.native.settings.modelPicker.options = pickerRows resolvedProxy;
      })
    ];
}

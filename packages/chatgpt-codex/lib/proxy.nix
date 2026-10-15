# Codex's half of `ai.proxy` (lib/ai/proxy): one provider table per endpoint,
# delivered where each backend can deliver it.
#
# ── Where the provider goes ───────────────────────────────────────────
# Home Manager writes `[model_providers.ai-proxy]` and `model_provider` into
# user config.toml. devenv cannot: Codex strips `model_provider` and
# `model_providers` from every project layer (PROJECT_LOCAL_CONFIG_DENYLIST,
# mirrored as `projectIgnoredKeys`), so its launcher passes them as `-c`
# session flags, the highest layer. Those flags carry configuration and the
# client key only, never an upstream credential.
#
# devenv uses its own provider id. Codex deep-merges layers per key, so a
# session flag reusing Home Manager's id would add its auth fields to the
# user table, and `auth` beside `experimental_bearer_token` (one key form in
# each layer) fails to load.
#
# ── The two selection forms ───────────────────────────────────────────
# Home Manager resolves both forms at evaluation (lib.ai.proxy `resolve`), so
# its user config.toml always gets an endpoint. devenv's launcher resolves an
# `instance` from the registry at every launch, through `ai-proxy-render`. A
# devenv shell inherits Home Manager's user config.toml with no devenv
# configuration.
#
# ── Auth ──────────────────────────────────────────────────────────────
# `plain` is `experimental_bearer_token`; `file` and `helper` are Codex's
# command-backed `auth`, re-run every five minutes and after a 401, so only
# the path reaches config. Never `env_key`: the variable is inherited by every
# tool subprocess, and Home Manager's launcher environment does not reach
# devenv's. `requires_openai_auth` stays false, or Codex sends a ChatGPT
# login's token to the proxy.
{
  inlineToml,
  lib,
  pkgs,
}: let
  proxyLib = lib.ai.proxy;

  ids = {
    devenv = "ai-proxy-devenv";
    hm = "ai-proxy";
  };

  # `name` is required: Codex refuses to load a provider without one.
  providerFor = id: endpoint:
    {
      base_url = "${endpoint.url}/v1";
      name = id;
      requires_openai_auth = false;
      wire_api = "responses";
    }
    // (
      if endpoint.key ? plain
      then {experimental_bearer_token = endpoint.key.plain;}
      else if endpoint.key ? file
      then {
        auth = {
          args = [endpoint.key.file];
          command = "${pkgs.coreutils}/bin/cat";
        };
      }
      else {auth.command = endpoint.key.helper;}
    );

  # devenv's renderer: the session flags for one endpoint, used on the
  # resolved endpoint at evaluation and, through `templates`, at launch.
  sessionFlags = endpoint: [
    "-c"
    "model_providers.${ids.devenv}=${inlineToml (providerFor ids.devenv endpoint)}"
    "-c"
    "model_provider=${ids.devenv}"
  ];
  templates = proxyLib.templatesFile pkgs "codex" sessionFlags;
  renderBin = lib.getExe (proxyLib.renderProgram pkgs);

  # makeWrapper arguments for devenv's launcher. The lookup's output is
  # captured with `$(…)`, so a missing registry or instance aborts the launch
  # under the wrapper's errexit instead of starting Codex without the proxy.
  launcherFlags = resolvedProxy:
    if resolvedProxy == null
    then []
    else if resolvedProxy ? endpoint
    then lib.concatMap (flag: ["--add-flag" (lib.escapeShellArg flag)]) (sessionFlags resolvedProxy.endpoint)
    else [
      "--run"
      (lib.escapeShellArg ''
        nat_proxy_flags="$(${renderBin} --lines ${lib.escapeShellArg resolvedProxy.instance} ${templates})"
        mapfile -t nat_proxy_flags <<<"$nat_proxy_flags"
        set -- "''${nat_proxy_flags[@]}" "$@"'')
    ];

  # Overridable defaults that keep Codex's side traffic off hosts other than
  # the proxy: plugin sync (github.com, chatgpt.com) and usage metrics.
  quietSettings = {
    analytics.enabled = lib.mkDefault false;
    features.plugins = lib.mkDefault false;
  };

  hmSettings = endpoint:
    quietSettings
    // {
      model_provider = ids.hm;
      model_providers.${ids.hm} = providerFor ids.hm endpoint;
    };
in {
  inherit hmSettings launcherFlags quietSettings;
}

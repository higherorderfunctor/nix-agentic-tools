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

  # devenv's renderer: the session flags for one endpoint.
  sessionFlags = endpoint: [
    "-c"
    "model_providers.${ids.devenv}=${inlineToml (providerFor ids.devenv endpoint)}"
    "-c"
    "model_provider=${ids.devenv}"
  ];

  # makeWrapper arguments for devenv's launcher.
  launcherFlags = resolvedProxy:
    if resolvedProxy == null
    then []
    else lib.concatMap (flag: ["--add-flag" (lib.escapeShellArg flag)]) (sessionFlags resolvedProxy.endpoint);

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

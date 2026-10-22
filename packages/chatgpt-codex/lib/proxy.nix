# Codex's half of `ai.proxy` (lib/ai/proxy): one provider table per endpoint,
# delivered where each backend can deliver it.
#
# ── Where the provider goes ───────────────────────────────────────────
# Home Manager writes `[model_providers.ai-proxy]` and `model_provider` into
# user config.toml. devenv cannot: Codex strips `model_provider` and
# `model_providers` from every project layer (PROJECT_LOCAL_CONFIG_DENYLIST,
# mirrored as `projectIgnoredKeys`), so its launcher passes them as `-c`
# session flags, the highest layer. Those flags carry configuration and the
# reference-reading helper only, never the resolved client key.
#
# devenv uses its own provider id. Codex deep-merges layers per key, so a
# session flag reusing Home Manager's id would add its auth fields to the
# user table, potentially inheriting a user's incompatible authentication
# fields alongside the proxy's command-backed `auth`.
#
# ── Auth ──────────────────────────────────────────────────────────────
# Every key uses command-backed `auth`, re-run every five minutes and after
# a 401. Its strict helper reads file, command or concat references through
# redact.assign and prints bytes with a constant format; no resolved value is
# interpolated into shell or TOML. Never `env_key`: the variable is inherited
# by every tool subprocess, and Home Manager's launcher environment does not
# reach devenv's. `requires_openai_auth` stays false, or Codex sends a ChatGPT
# login's token to the proxy.
#
# ── Providers ─────────────────────────────────────────────────────────
# Codex lists the proxy's models with no setting: `auth.command` makes it
# fetch `<base_url>/models?client_version=`, which CLIProxyAPI answers in
# Codex's own catalog shape, merged into the bundled list. Codex has no
# per-provider default model, so Home Manager writes one profile per enabled
# provider, `<configDir>/<name>.config.toml`, selecting its first model:
# `codex -p <name>`. A profile lives in CODEX_HOME, which devenv does not
# own, so devenv writes none and warns.
{
  inlineToml,
  lib,
  pkgs,
}: let
  redact = import ../../../lib/redact {inherit lib;};
  ids = {
    devenv = "ai-proxy-devenv";
    hm = "ai-proxy";
  };

  # `name` is required: Codex refuses to load a provider without one.
  providerFor = id: endpoint: let
    helper = import ../../../lib/strict-shell-application.nix pkgs {
      name = "codex-proxy-key";
      text = ''
        # Reference paths and concat literals are already shell-escaped.
        # shellcheck disable=SC2016
        ${redact.assign {
          inherit pkgs;
          option = "ai.codex.proxy.key";
          value = endpoint.key;
          variable = "key";
        }}
        printf '%s' "$key"
      '';
    };
  in {
    auth.command = lib.getExe helper;
    base_url = "${endpoint.url}/v1";
    name = id;
    requires_openai_auth = false;
    wire_api = "responses";
  };

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
    else lib.concatMap (flag: ["--add-flag" (lib.escapeShellArg flag)]) (sessionFlags resolvedProxy);

  hmSettings = endpoint: {
    model_provider = ids.hm;
    model_providers.${ids.hm} = providerFor ids.hm endpoint;
  };

  # Home Manager's profile documents: file name under configDir → settings.
  hmProfiles = resolvedProxy:
    lib.listToAttrs (map (provider:
        lib.nameValuePair "${provider.name}.config.toml" {
          model = lib.head provider.models;
          model_provider = ids.hm;
        })
      (
        if resolvedProxy == null
        then []
        else resolvedProxy.providers
      ));
in {
  inherit hmProfiles hmSettings launcherFlags;
}

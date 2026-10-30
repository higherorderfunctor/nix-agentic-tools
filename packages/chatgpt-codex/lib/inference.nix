# Codex's half of `ai.settings.inference` (lib/ai/inference): one provider table per endpoint,
# delivered where each backend can deliver it. Only the CLIProxyAPI lowering
# exists; it also lowers an external `url` + `key`.
#
# ── Where the provider goes ───────────────────────────────────────────
# Home Manager writes `[model_providers.ai-inference]` and `model_provider` into
# user config.toml. devenv cannot: Codex strips `model_provider` and
# `model_providers` from every project layer (PROJECT_LOCAL_CONFIG_DENYLIST,
# mirrored as `projectIgnoredKeys`), so its launcher passes them as `-c`
# session flags, the highest layer. Home Manager's keys are defaults, so a
# consumer's own `native.settings` value wins. Those flags carry configuration and the
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
# Codex's own catalog shape, merged into the bundled list. Client routes
# determine which upstream credentials requests reach.
{
  inlineToml,
  lib,
  pkgs,
}: let
  keyHelper = import ../../../lib/ai/inference/key-helper.nix {inherit lib pkgs;};
  inferenceLib = import ../../../lib/ai/inference {inherit lib;};
  ids = {
    devenv = "ai-inference-devenv";
    hm = "ai-inference";
  };

  # `name` is required: Codex refuses to load a provider without one.
  providerFor = id: endpoint: let
    helper = keyHelper {
      inherit (endpoint) key;
      option = "ai.codex.settings.inference.key";
    };
  in {
    auth.command = lib.getExe helper;
    base_url = "${endpoint.url}/v1";
    name = id;
    requires_openai_auth = false;
    wire_api = "responses";
  };

  # A lowering returns `settings` for both backends and, optionally,
  # `hmSettings` for user config.toml and `sessionFlags` for devenv's launcher.
  lowerings.cliproxyapi = {resolvedInference}: {
    hmSettings = {
      model_provider = ids.hm;
      model_providers.${ids.hm} = providerFor ids.hm resolvedInference;
    };
    # devenv's renderer: the session flags for one endpoint.
    sessionFlags = [
      "-c"
      "model_providers.${ids.devenv}=${inlineToml (providerFor ids.devenv resolvedInference)}"
      "-c"
      "model_provider=${ids.devenv}"
    ];
    # Codex 0.163.0: startup_prompts.rs stops at four impressions. Its bundled
    # models.json announces only gpt-6.1-sol; extracted models omit
    # availability_nux.
    settings.tui.model_availability_nux."gpt-6.1-sol" = 4;
  };
  inferenceLowering = inferenceLib.forRuntime "codex" lowerings;
in {
  inherit (inferenceLowering) assertions;

  # makeWrapper arguments for devenv's launcher.
  launcherFlags = resolvedInference:
    lib.concatMap (flag: ["--add-flag" (lib.escapeShellArg flag)]) ((inferenceLowering.lower {inherit resolvedInference;}).sessionFlags or []);

  # Native settings for a selected proxy, at default priority.
  settings = isHm: resolvedInference: let
    lowered = inferenceLowering.lower {inherit resolvedInference;};
  in
    lib.mapAttrsRecursive (_: lib.mkDefault) (lib.recursiveUpdate (lowered.settings or {})
      (lib.optionalAttrs isHm (lowered.hmSettings or {})));
}

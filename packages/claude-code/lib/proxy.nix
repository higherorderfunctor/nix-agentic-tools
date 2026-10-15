# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files, never through process env, which any settings `env` beats.
#
# One renderer (`render`) serves both forms of the resolved selection (see
# lib/ai/proxy/default.nix): applied to the endpoint at evaluation, and
# through `templates` filled from the registry at run time for devenv's
# `instance` form. Where each form lands:
#
#   * an endpoint (`url`, or an `instance` Home Manager resolved at
#     evaluation): `native.settings`, so the settings.json each backend
#     already writes (user on Home Manager, project on devenv).
#   * `instance`, devenv: `.claude/settings.local.json`, the highest file
#     scope, rendered at shell entry. Claude saves its own permission answers
#     in that file, so it is a reconciled document: only the proxy leaves are
#     owned, every other key is left alone, and the leaves are retracted when
#     the selection goes away.
{
  lib,
  pkgs,
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  proxyLib = lib.ai.proxy;

  # The endpoint as Claude settings. The url is the origin: Claude appends
  # `/v1/messages` itself. Every proxy writes BOTH key methods, the unused one
  # blank, because settings merge per key across scopes: a helper left in a
  # lower scope beside a token here (or the reverse) would send that other
  # key to this proxy too. `ANTHROPIC_API_KEY` is blanked, never set: an
  # interactive session asks before using a value, and declining sends the
  # claude.ai login instead; left unset, one inherited from the process env or
  # another scope rides along as `x-api-key`, an upstream credential sent to
  # the proxy.
  render = {
    key,
    url,
  }: {
    apiKeyHelper =
      if key ? file
      then "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg key.file}"
      else key.helper or "";
    env = {
      ANTHROPIC_API_KEY = "";
      ANTHROPIC_AUTH_TOKEN = key.plain or "";
      ANTHROPIC_BASE_URL = url;
    };
  };
  # The leaves `render` owns, as attribute paths, read off the renderer so the
  # list cannot drift from it.
  ownedPaths = lib.collect lib.isList (lib.mapAttrsRecursive (path: _: path) (render {
    key.plain = "";
    url = "";
  }));

  templates = proxyLib.templatesFile pkgs "claude" render;
  # Compact JSON of `render` for the instance, or a non-zero exit naming the
  # registry and the instance.
  lookup = instance: ''"$(${lib.getExe (proxyLib.renderProgram pkgs)} ${lib.escapeShellArg instance} ${templates})"'';
  jq = lib.getExe pkgs.jq;

  # Without a proxy these reach api.anthropic.com and downloads.claude.ai
  # directly. Defaults, so a consumer can turn either back on.
  quietEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
  };

  localSettings = ".claude/settings.local.json";
  writer = "claudeProxySettings";
  ledger = "json-settings/claude-proxy-settings-local.json";
in {
  # devenv's writer for the `instance` form, declared whatever is selected
  # and while Claude is disabled, so the generation that drops the selection
  # or disables Claude retracts what an earlier one wrote.
  writerConfig = {
    ai.claude.activation.${writer} = {
      entry = "ai:claude:proxy-settings";
      ledgers.${ledger} = {
        codec = "json";
        path = localSettings;
      };
      runWhenDisabled = true;
    };
  };

  config = {
    backend,
    nativeSettings,
    resolvedProxy,
  }: let
    setByConsumer = builtins.filter (path: lib.hasAttrByPath path nativeSettings) ownedPaths;
  in
    lib.mkMerge [
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings.env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (resolvedProxy ? endpoint) {
        ai.claude.native.settings = render resolvedProxy.endpoint;
      })
      # The run-time form cannot conflict at evaluation, so the same rule is
      # an assertion: the rendered endpoint would silently replace the value.
      (lib.mkIf (backend == "devenv" && resolvedProxy ? instance) {
        assertions = [
          {
            assertion = setByConsumer == [];
            message = "ai.claude.native.settings sets ${lib.concatMapStringsSep ", " lib.showOption setByConsumer}, which the selected ai.proxy instance \"${resolvedProxy.instance}\" writes. Remove it, or select the proxy with `url` and `key` instead.";
          }
        ];
      })
      (lib.optionalAttrs (backend == "devenv") (lib.mkIf (resolvedProxy ? instance) (helpers.mkReconciledDocument {
        content = {
          _generated = true;
          _surface = "settings";
          # An existing file is the user's or Claude's. Until this ledger
          # owns leaves in it, a proxy leaf already there was written by
          # someone else, and replacing it (then deleting it on retraction)
          # would lose it, so the shell entry fails instead.
          run = ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            instance=${lib.escapeShellArg resolvedProxy.instance}
            proxy=${lookup resolvedProxy.instance}
            target="''${NAT_OWN_ROOT:?}"/${localSettings}
            if [ ! -e "''${NAT_OWN_STATE:?}"/${ledger} ] && [ -f "$target" ]; then
              taken="$(${jq} --raw-output --argjson proxy "$proxy" \
                '. as $settings | [$proxy | paths(scalars) | select(. as $path | ($settings | try getpath($path) catch null) != null) | join(".")] | join(", ")' \
                "$target")"
              if [ -n "$taken" ]; then
                echo "ai.claude: $target already sets $taken, which ai.proxy instance \"$instance\" writes. Remove those keys from the file and re-enter the shell (ai.proxy owns only them; every other key there is left alone), or drop the devenv ai.proxy selection to keep them." >&2
                exit 1
              fi
            fi
            printf '%s\n' "$proxy"
          '';
        };
        format = "json";
        inherit ledger;
        path = localSettings;
        runtime = "claude";
        inherit writer;
      })))
    ];
}

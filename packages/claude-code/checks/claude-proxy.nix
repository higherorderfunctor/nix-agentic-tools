# `ai.proxy` delivered to Claude Code (packages/claude-code/lib/proxy.nix):
# the `url` form in each backend's settings.json, the key forms, the blanked
# second key method, the quiet defaults, and the guards.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  evals = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  perBackend = name: test:
    lib.mapAttrs' (backend: eval:
      lib.nameValuePair "module-claude-${backend}-proxy-${name}"
      (mkTest "claude-${backend}-proxy-${name}" (test eval)))
    evals;
  withClaude = config: lib.recursiveUpdate {ai.claude.enable = true;} config;
  origin = "http://127.0.0.1:8317";
  urlForm = key: {
    ai.proxy = {
      inherit key;
      url = origin;
    };
  };
  quiet = settings:
    settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    == "1"
    && settings.env.DISABLE_AUTOUPDATER == "1";
in {
  checks = lib.mergeAttrsList [
    # Each key form lands as one method with the other blanked, beside the
    # origin and the quiet defaults; `ANTHROPIC_API_KEY` is always blank, so
    # an inherited one is not sent to the proxy, and never holds the key.
    (perBackend "url-key-forms" (eval: let
      settingsFor = key: claudeSettings (eval (withClaude (urlForm key)));
      plain = settingsFor {plain = "sk-local";};
      file = settingsFor {file = "/run/secrets/ai-proxy-key";};
      helper = settingsFor {helper = "/run/current-system/sw/bin/proxy-key";};
    in
      lib.all (settings: settings.env.ANTHROPIC_BASE_URL == origin && quiet settings && settings.env.ANTHROPIC_API_KEY == "") [plain file helper]
      && plain.env.ANTHROPIC_AUTH_TOKEN == "sk-local"
      && plain.apiKeyHelper == ""
      && file.env.ANTHROPIC_AUTH_TOKEN == ""
      && file.apiKeyHelper == "${pkgs.coreutils}/bin/cat /run/secrets/ai-proxy-key"
      && helper.env.ANTHROPIC_AUTH_TOKEN == ""
      && helper.apiKeyHelper == "/run/current-system/sw/bin/proxy-key"))

    # The quiet defaults yield to a consumer's value; a consumer's value for a
    # proxy leaf conflicts instead of silently winning or losing; nothing
    # selected writes nothing, and a selection no longer warns that Claude
    # ignores ai.proxy.
    (perBackend "precedence" (eval: let
      overridden = claudeSettings (eval (withClaude (lib.recursiveUpdate (urlForm {plain = "sk-local";}) {
        ai.claude.native.settings.env.DISABLE_AUTOUPDATER = "0";
      })));
      conflicting = eval (withClaude (lib.recursiveUpdate (urlForm {plain = "sk-local";}) {
        ai.claude.native.settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:9999";
      }));
      unselected = eval (withClaude {});
      selected = eval (withClaude (urlForm {plain = "sk-local";}));
    in
      overridden.env.DISABLE_AUTOUPDATER
      == "0"
      && !(builtins.tryEval (builtins.deepSeq (claudeSettings conflicting) true)).success
      && !((claudeSettings unselected).env or {} ? ANTHROPIC_BASE_URL)
      && !((claudeSettings unselected).env or {} ? DISABLE_AUTOUPDATER)
      && !(builtins.any (lib.hasInfix "does not deliver it to claude") selected.config.warnings)))

    # `ai.claude.proxy` replaces the root selection whole.
    (perBackend "runtime-override" (eval: let
      result = eval (withClaude (lib.recursiveUpdate (urlForm {plain = "sk-root";}) {
        ai.claude.proxy = {
          key.file = "/run/secrets/work-key";
          url = "http://127.0.0.1:8318";
        };
      }));
      settings = claudeSettings result;
    in
      result.config.ai.claude.normalized.proxy.endpoint.url
      == "http://127.0.0.1:8318"
      && settings.env.ANTHROPIC_AUTH_TOKEN == ""
      && lib.hasSuffix "/bin/cat /run/secrets/work-key" settings.apiKeyHelper))
  ];
}

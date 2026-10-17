# cspell:ignore urandom
# `ai.proxy` delivered to Claude Code (packages/claude-code/lib/proxy.nix):
# the `url` form in each backend's settings.json, reference-reading helpers,
# cleared inherited credentials, quiet defaults, and the guards.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  redact = import ../../../lib/redact {inherit lib;};
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
  file = "/tmp/claude-proxy $(touch injected) ' key";
  command = lib.getExe (import ../../../lib/strict-shell-application.nix pkgs {
    name = "claude-proxy-test-command";
    text = ''
      printf '%s' "$CLAUDE_PROXY_TEST_VALUE"
      exit "$CLAUDE_PROXY_TEST_STATUS"
    '';
  });
  keys = {
    command = redact.command command;
    concat = redact.concat ["Bearer \"" (redact.file file) "\" $suffix"];
    file = redact.file file;
  };
  settingsFor = eval: key: claudeSettings (eval (withClaude (urlForm key)));
  quiet = settings:
    settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    == "1"
    && settings.env.DISABLE_AUTOUPDATER == "1";
in {
  checks = lib.mergeAttrsList [
    # Every reference uses the reader through apiKeyHelper; neither inherited
    # authentication variable may accompany that key.
    (perBackend "url-key-forms" (eval:
      lib.all (settings:
        settings.env.ANTHROPIC_BASE_URL
        == origin
        && quiet settings
        && settings.env.ANTHROPIC_API_KEY == ""
        && settings.env.ANTHROPIC_AUTH_TOKEN == "")
      (map (settingsFor eval) (builtins.attrValues keys))))

    # The quiet defaults yield to a consumer's value; a consumer's value for a
    # proxy leaf conflicts instead of silently winning or losing; nothing
    # selected writes nothing, and a selection no longer warns that Claude
    # ignores ai.proxy.
    (perBackend "precedence" (eval: let
      overridden = claudeSettings (eval (withClaude (lib.recursiveUpdate (urlForm (redact.file "/run/secrets/ai-proxy-key")) {
        ai.claude.native.settings.env.DISABLE_AUTOUPDATER = "0";
      })));
      conflicting = eval (withClaude (lib.recursiveUpdate (urlForm (redact.file "/run/secrets/ai-proxy-key")) {
        ai.claude.native.settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:9999";
      }));
      unselected = eval (withClaude {});
      selected = eval (withClaude (urlForm (redact.file "/run/secrets/ai-proxy-key")));
    in
      overridden.env.DISABLE_AUTOUPDATER
      == "0"
      && !(builtins.tryEval (builtins.deepSeq (claudeSettings conflicting) true)).success
      && !((claudeSettings unselected).env or {} ? ANTHROPIC_BASE_URL)
      && !((claudeSettings unselected).env or {} ? DISABLE_AUTOUPDATER)
      && !(builtins.any (lib.hasInfix "does not deliver it to claude") selected.config.warnings)))

    # `ai.claude.proxy` replaces the root selection whole.
    (perBackend "runtime-override" (eval: let
      result = eval (withClaude (lib.recursiveUpdate (urlForm (redact.file "/run/secrets/root-key")) {
        ai.claude.proxy = {
          key = redact.file "/run/secrets/work-key";
          url = "http://127.0.0.1:8318";
        };
      }));
      settings = claudeSettings result;
    in
      result.config.ai.claude.normalized.proxy.endpoint.url
      == "http://127.0.0.1:8318"
      && settings.env.ANTHROPIC_AUTH_TOKEN == ""
      && result.config.ai.claude.normalized.proxy.endpoint.key == redact.file "/run/secrets/work-key"
      && settings.apiKeyHelper == (settingsFor eval (redact.file "/run/secrets/work-key")).apiKeyHelper))
    {
      claude-proxy-runtime =
        pkgs.runCommand "claude-proxy-runtime" {
          nativeBuildInputs = [pkgs.python3];
          settings = pkgs.writeText "claude-proxy-runtime-settings.json" (builtins.toJSON (
            lib.mapAttrs (_: eval: lib.mapAttrs (_: settingsFor eval) keys) evals
          ));
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 - <<'PYTHON'
          import json
          import os
          from pathlib import Path
          import subprocess

          settings = json.loads(Path(os.environ["settings"]).read_text())
          path = Path(${builtins.toJSON file})
          # Generated only at build time: a leaked value cannot hide in the source.
          secret = "secret-" + os.urandom(16).hex() + " ' \" \\ $HOME $(touch injected) `touch injected`\nnext"
          env = dict(os.environ, ANTHROPIC_API_KEY="upstream-api-key", ANTHROPIC_AUTH_TOKEN="upstream-token")
          env.update(CLAUDE_PROXY_TEST_STATUS="0", CLAUDE_PROXY_TEST_VALUE=secret + "\n\n")
          cases = 0
          for backend, forms in settings.items():
              for name, config in forms.items():
                  path.write_text(secret + "\n\n")
                  child_env = env | config["env"]
                  assert child_env["ANTHROPIC_API_KEY"] == child_env["ANTHROPIC_AUTH_TOKEN"] == ""
                  def run():
                      return subprocess.run(["${pkgs.bash}/bin/bash", "-c", config["apiKeyHelper"]], env=child_env, capture_output=True, text=True)
                  result = run()
                  expected = 'Bearer "' + secret + '" $suffix' if name == "concat" else secret
                  assert (result.returncode, result.stdout, result.stderr) == (0, expected, ""), (backend, name, result.returncode)
                  assert not Path("injected").exists(), (backend, name, "shell injection")
                  cases += 1
                  # The consumer must abort without returning or printing a secret.
                  if name == "command":
                      child_env["CLAUDE_PROXY_TEST_STATUS"] = "7"
                  else:
                      path.unlink()
                  result = run()
                  assert result.returncode != 0 and result.stdout == "", (backend, name, "failed reference succeeded")
                  assert "ai.claude.proxy.key:" in result.stderr and secret not in result.stderr
                  cases += 1
          print(f"verified {cases} Claude helper cases: file, command, concat, failures and inherited credentials on both backends")
          PYTHON
          touch "$out"
        '';
    }
  ];
}

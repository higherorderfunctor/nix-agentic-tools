# cspell:ignore urandom wfile
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
  installed = result: builtins.head (result.config.home.packages or result.config.packages);
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
      withoutPackage = eval (withClaude (lib.recursiveUpdate (urlForm keys.file) {ai.claude.package = null;}));
    in
      overridden.env.DISABLE_AUTOUPDATER
      == "0"
      && !(builtins.tryEval (builtins.deepSeq (claudeSettings conflicting) true)).success
      && installed unselected == unselected.config.ai.claude.package
      && (withoutPackage.config.home.packages or withoutPackage.config.packages) == []
      && builtins.any (lib.hasInfix "only the managed launcher suppresses") withoutPackage.config.warnings
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
      result.config.ai.claude.normalized.proxy.url
      == "http://127.0.0.1:8318"
      && settings.env.ANTHROPIC_AUTH_TOKEN == ""
      && result.config.ai.claude.normalized.proxy.key == redact.file "/run/secrets/work-key"
      && settings.apiKeyHelper == (settingsFor eval (redact.file "/run/secrets/work-key")).apiKeyHelper))
    # The live run binds a loopback port, which the Darwin sandbox refuses.
    (lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      claude-proxy-runtime =
        pkgs.runCommand "claude-proxy-runtime" {
          nativeBuildInputs = [pkgs.python3];
          launchers = pkgs.writeText "claude-proxy-runtime-launchers.json" (builtins.toJSON (
            lib.mapAttrs (_: eval:
              lib.getExe' (installed (eval (withClaude (lib.recursiveUpdate (urlForm keys.file) {
                ai.claude.package = pkgs.ai.claude-code;
              })))) "claude")
            evals
          ));
          settings = pkgs.writeText "claude-proxy-runtime-settings.json" (builtins.toJSON (
            lib.mapAttrs (_: eval: lib.mapAttrs (_: settingsFor eval) keys) evals
          ));
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 - <<'PYTHON'
          import http.server
          import json
          import os
          from pathlib import Path
          import subprocess
          import threading

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

          # Execute the actual pinned CLI through each backend's installed
          # launcher: helper-only checks miss Claude's early descriptor cache.
          records = []
          received = threading.Event()
          class Handler(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  records.append((self.path, self.headers.get("x-api-key"), self.headers.get("authorization"), dict(self.headers)))
                  self.send_response(401)
                  self.end_headers()
                  self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"test proxy"}}')
                  received.set()
              def log_message(self, *args):
                  pass
          server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
          threading.Thread(target=server.serve_forever, daemon=True).start()
          secret = "proxy-" + os.urandom(16).hex()
          path.write_text(secret)
          launchers = json.loads(Path(os.environ["launchers"]).read_text())
          try:
              for backend, launcher in launchers.items():
                  root = Path(backend).resolve()
                  user = root / "user"
                  user.mkdir(parents=True)
                  config = settings[backend]["file"]
                  config["env"]["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{server.server_port}"
                  # Each backend's own scope: Home Manager writes user
                  # settings, devenv the project's .claude/settings.json.
                  scope = user if backend == "hm" else root / ".claude"
                  scope.mkdir(exist_ok=True)
                  (scope / "settings.json").write_text(json.dumps(config))
                  records.clear()
                  received.clear()
                  rd, wr = os.pipe()
                  os.write(wr, b"inherited-descriptor-key")
                  os.close(wr)
                  child_env = dict(os.environ, HOME=str(root), CLAUDE_CONFIG_DIR=str(user),
                                   CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR=str(rd),
                                   ANTHROPIC_API_KEY="inherited-api-key", ANTHROPIC_AUTH_TOKEN="inherited-token",
                                   ANTHROPIC_CUSTOM_HEADERS="x-inherited-credential: inherited-header",
                                   CLAUDE_CODE_USE_BEDROCK="1", CLAUDE_CODE_USE_FOUNDRY="1", CLAUDE_CODE_USE_VERTEX="1",
                                   TERM="dumb")
                  try:
                      process = subprocess.Popen([launcher, "-p", "hello", "--model", "claude-sonnet-4-5", "--max-turns", "1"],
                                                 cwd=root, env=child_env, pass_fds=(rd,),
                                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                      try:
                          assert received.wait(20), (backend, "no request from pinned Claude")
                      finally:
                          process.terminate()
                          try:
                              process.communicate(timeout=5)
                          except subprocess.TimeoutExpired:
                              process.kill()
                              process.communicate()
                  finally:
                      os.close(rd)
                  assert records and all(url.startswith("/v1/messages") and key == secret and auth == "Bearer " + secret
                                         for url, key, auth, _ in records), (backend, "selected credentials did not reach proxy alone")
                  leaked = [name for *_, headers in records for name, value in headers.items() if "inherited" in value]
                  assert not leaked, (backend, "inherited credential in headers", leaked)
                  print(f"verified {backend} pinned Claude HTTP request: selected key in x-api-key and Authorization; inherited descriptor, keys, headers and provider switches suppressed")
          finally:
              server.shutdown()
              server.server_close()
          PYTHON
          touch "$out"
        '';
    })
  ];
}

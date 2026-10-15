# `ai.proxy` delivered to Claude Code (packages/claude-code/lib/proxy.nix):
# the `url` form in each backend's settings.json, the `instance` form resolved
# at evaluation (Home Manager) or rendered at shell entry (devenv), the key
# forms, the blanked second key method, the quiet defaults, and the guards.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase claudeSettings evalDevenv evalHm mkTest;
  proxyLib = aiBase.proxy;
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
  failedMessages = result: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) result.config.assertions);
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
  registry = builtins.toJSON {
    main = {
      key.plain = "sk-local";
      url = origin;
    };
  };
  # A file entry's `content.run`, as a script the check can execute.
  runOf = result: path: pkgs.writeText "claude-proxy-run" result.config.ai.claude.files.${path}.content.run;
  devenvInstance = evalDevenv (withClaude {ai.proxy.instance = "main";});
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
    # selected writes nothing and no longer warns that Claude ignores ai.proxy.
    (perBackend "precedence" (eval: let
      overridden = claudeSettings (eval (withClaude (lib.recursiveUpdate (urlForm {plain = "sk-local";}) {
        ai.claude.native.settings.env.DISABLE_AUTOUPDATER = "0";
      })));
      conflicting = eval (withClaude (lib.recursiveUpdate (urlForm {plain = "sk-local";}) {
        ai.claude.native.settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:9999";
      }));
      unselected = eval (withClaude {});
      selected = eval (withClaude {ai.proxy.instance = "main";});
    in
      overridden.env.DISABLE_AUTOUPDATER
      == "0"
      && !(builtins.tryEval (builtins.deepSeq (claudeSettings conflicting) true)).success
      && !((claudeSettings unselected).env or {} ? ANTHROPIC_BASE_URL)
      && !(unselected.config.ai.claude.files ? ".claude/settings.local.json")
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

    {
      # Home Manager instance: resolved at evaluation to the entry Home
      # Manager declares, through the same renderer as the `url` form, into
      # the ordinary store-linked settings.json; an undeclared name fails.
      module-claude-hm-proxy-instance-resolves = mkTest "claude-hm-proxy-instance-resolves" (
        let
          declared = evalHm (withClaude {
            ai.proxy = {
              instance = "main";
              instances.main.clientKey.plain = "sk-local";
            };
          });
          settings = claudeSettings declared;
        in
          failedMessages declared
          == []
          && declared.config.home.file ? ".claude/settings.json"
          && settings.env.ANTHROPIC_AUTH_TOKEN == "sk-local"
          && settings.env.ANTHROPIC_BASE_URL == origin
          && settings.apiKeyHelper == ""
          && quiet settings
          && builtins.any (lib.hasInfix "ai.claude is pointed at ai.proxy instance \"main\", which Home Manager does not declare") (failedMessages (evalHm (withClaude {ai.proxy.instance = "main";})))
      );

      # The devenv instance form cannot conflict at evaluation, so a
      # consumer's proxy leaf fails an assertion naming it.
      module-claude-devenv-proxy-instance-consumer-leaf-asserted = mkTest "claude-devenv-proxy-instance-consumer-leaf-asserted" (
        builtins.any (lib.hasInfix "ai.claude.native.settings sets env.ANTHROPIC_BASE_URL, which the selected ai.proxy instance \"main\" writes") (failedMessages (evalDevenv (withClaude {
          ai = {
            claude.native.settings.env.ANTHROPIC_BASE_URL = origin;
            proxy.instance = "main";
          };
        })))
      );

      # The devenv writer is declared with nothing selected and with Claude
      # disabled, so dropping the selection or disabling Claude retracts its
      # output.
      module-claude-devenv-proxy-writer-always-declared = mkTest "claude-devenv-proxy-writer-always-declared" (
        lib.all (config: (evalDevenv config).config.ai.claude.activation ? claudeProxySettings) [{} (withClaude {})]
      );

      # devenv instance: the project settings.json carries only the quiet
      # defaults; settings.local.json is a reconciled document whose renderer
      # prints the endpoint, keeps out of a file Claude or the user wrote, and
      # fails loudly on a proxy leaf someone else put there until the ledger
      # owns it.
      module-claude-devenv-proxy-instance-renders-local-settings = let
        entry = devenvInstance.config.ai.claude.files.".claude/settings.local.json";
        project = claudeSettings devenvInstance;
        run = runOf devenvInstance ".claude/settings.local.json";
      in
        assert entry.facts.harnessWrites;
        assert devenvInstance.config.ai.claude.activation.claudeProxySettings.ledgers.${entry.ledger}.path == ".claude/settings.local.json";
        assert quiet project && !(project.env ? ANTHROPIC_BASE_URL) && !(project ? apiKeyHelper);
        assert failedMessages devenvInstance == [];
          pkgs.runCommand "module-test-claude-devenv-proxy-instance-renders-local-settings" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            jq=${lib.getExe pkgs.jq}
            export HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/config" NAT_OWN_ROOT="$PWD/project" NAT_OWN_STATE="$PWD/state"
            mkdir -p config/ai-proxy project/.claude state
            printf '%s' ${lib.escapeShellArg registry} >config/${proxyLib.registryPath}
            expected='{"apiKeyHelper":"","env":{"ANTHROPIC_API_KEY":"","ANTHROPIC_AUTH_TOKEN":"sk-local","ANTHROPIC_BASE_URL":"${origin}"}}'

            [ "$(bash ${run})" = "$expected" ]
            printf '{"permissions":{"allow":["Bash(ls)"]}}' >project/.claude/settings.local.json
            [ "$(bash ${run})" = "$expected" ]

            printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:9"},"apiKeyHelper":"x"}' >project/.claude/settings.local.json
            if bash ${run} 2>err; then
              echo "expected a refusal of a hand-written proxy leaf" >&2
              exit 1
            fi
            grep -qF 'already sets apiKeyHelper, env.ANTHROPIC_BASE_URL, which ai.proxy instance "main" writes' err

            mkdir -p state/$(dirname ${entry.ledger})
            : >state/${entry.ledger}
            [ "$(bash ${run})" = "$expected" ]
            "$jq" -e . <<<"$expected" >/dev/null
            echo PASS >$out
          '';

      # The real shell-entry writer across shells: it adds the proxy leaves
      # beside the keys Claude saved, re-enters cleanly once it owns them, and
      # retracts only its own leaves when the selection is dropped.
      module-claude-devenv-proxy-local-settings-lifecycle = let
        task = result:
          pkgs.writeShellScript "claude-proxy-settings-task" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            ${result.config.tasks."ai:claude:proxy-settings".exec}
          '';
      in
        pkgs.runCommand "module-test-claude-devenv-proxy-local-settings-lifecycle" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          jq=${lib.getExe pkgs.jq}
          export HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/config" DEVENV_ROOT="$PWD/project" DEVENV_STATE="$PWD/state"
          local_settings=project/.claude/settings.local.json
          mkdir -p config/ai-proxy project/.claude state
          printf '%s' ${lib.escapeShellArg registry} >config/${proxyLib.registryPath}
          printf '{"permissions":{"allow":["Bash(ls)"]}}' >"$local_settings"

          ${task devenvInstance}
          ${task devenvInstance}
          "$jq" -e --arg origin ${origin} '
            . == {
              apiKeyHelper: "",
              env: {ANTHROPIC_API_KEY: "", ANTHROPIC_AUTH_TOKEN: "sk-local", ANTHROPIC_BASE_URL: $origin},
              permissions: {allow: ["Bash(ls)"]}
            }
          ' "$local_settings" >/dev/null

          ${task (evalDevenv (withClaude {}))}
          "$jq" -e '. == {permissions: {allow: ["Bash(ls)"]}}' "$local_settings" >/dev/null
          echo PASS >$out
        '';
    }
  ];
}

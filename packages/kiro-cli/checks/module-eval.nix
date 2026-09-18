# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm hasLiteral mkTest mkWrapperGrepTest ownedDocument;
  cliDocument = evaluated:
    ownedDocument "kiro" "${evaluated.config.ai.kiro.configDir}/settings/cli.json" evaluated;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) dvHookTarget dvHookTaskExec dvMcpDirTarget dvMcpDocTarget dvMcpTaskExec dvTaskExec hmHookPruneScript hmHookTarget hmHookWriteScript hmMcpDirTarget hmMcpDocTarget hmMcpPruneScript hmMcpWriteScript hmRetirementScript idempotentFlags kiroSteeringFiles kiroWrappedDrvs ownPlanArg renderKiroSecrets renderedMcpJson soleFork soleSame;
in {
  checks = {
    module-kiro-wrapper-prepend-both = mkTest "kiro-wrapper-prepend-both" (
      let
        b = idempotentFlags.idempotentFlagBlock {
          flags = ["--tui" "--v3"];
          position = "prepend";
        };
        tuiLine = ''if [ "$nat_seen_tui" = 0 ]; then set -- --tui "$@"; fi'';
        v3Line = ''if [ "$nat_seen_v3" = 0 ]; then set -- --v3 "$@"; fi'';
      in
        lib.hasInfix "nat_seen_tui=0" b
        && lib.hasInfix "nat_seen_v3=0" b
        && lib.hasInfix "--tui) nat_seen_tui=1 ;;" b
        && lib.hasInfix "--v3) nat_seen_v3=1 ;;" b
        && lib.hasInfix tuiLine b
        && lib.hasInfix v3Line b
        # reverse emission order is what makes the result `--tui --v3 …`
        && (lib.length (lib.splitString v3Line (lib.head (lib.splitString tuiLine b))) == 2)
    );

    # The append form is still available for a genuinely per-subcommand
    # option, and must NOT be reachable by accident: `position` has no
    # default, since picking the wrong one is the exact bug this guards.
    module-kiro-wrapper-append-form = mkTest "kiro-wrapper-append-form" (
      let
        b = idempotentFlags.idempotentFlagBlock {
          flags = ["--v3"];
          position = "append";
        };
      in
        lib.hasInfix ''if [ "$nat_seen_v3" = 0 ]; then set -- "$@" --v3; fi'' b
        && !(lib.hasInfix "tui" b)
    );

    module-kiro-wrapper-rejects-bad-position =
      mkTest "kiro-wrapper-rejects-bad-position" (!(builtins.tryEval (idempotentFlags.idempotentFlagBlock {
        flags = ["--v3"];
        position = "middle";
      }))
    .success);

    module-kiro-wrapper-idempotent-none = mkTest "kiro-wrapper-idempotent-none" (
      idempotentFlags.idempotentFlagBlock {
        flags = [];
        position = "prepend";
      }
      == ""
    );

    # ── Kiro launcher wrapper: subcommand gating ─────────────────────
    # Used for the options that genuinely ARE per-subcommand: `--tui`
    # (meaningless outside a bare launch and `chat`) and the chat
    # binary's `--trust-tools`. The scan resolves the subcommand into
    # nat_sub; the value-flag arm keeps `--agent acp` from reading as the
    # acp subcommand; `--` parks on a sentinel no gate matches.
    module-kiro-wrapper-subcommand-scan = mkTest "kiro-wrapper-subcommand-scan" (
      let
        b = idempotentFlags.subcommandBlock ["--agent" "--resume-id"];
      in
        lib.hasInfix ''nat_sub=""'' b
        && lib.hasInfix "--agent|--resume-id) nat_skip=1 ;;" b
        && lib.hasInfix ''--) nat_sub="--"; break ;;'' b
        && lib.hasInfix "-*) ;;" b
        && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
    );

    # No value-taking options ⇒ no skip arm, but the scan still resolves
    # a subcommand (a wrapper with only boolean options still needs it).
    module-kiro-wrapper-subcommand-scan-boolean-only = mkTest "kiro-wrapper-subcommand-scan-boolean-only" (
      let
        b = idempotentFlags.subcommandBlock [];
      in
        !(lib.hasInfix "nat_skip=1 ;;" b)
        && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
    );

    # The gate wraps the injection in a `case` over the accepted set.
    # `bareInvocation` is the empty string, so a gate covering the bare
    # launch emits a `''`-quoted alternative ahead of the named ones.
    module-kiro-wrapper-gate-wraps-injection = mkTest "kiro-wrapper-gate-wraps-injection" (
      let
        b = idempotentFlags.gateOnSubcommand {
          subcommands = [idempotentFlags.bareInvocation "chat"];
          valueFlags = ["--agent"];
        } "INJECTED";
      in
        lib.hasInfix ''case "$nat_sub" in'' b
        && lib.hasInfix "  ''|chat)" b
        && lib.hasInfix "    INJECTED" b
        && lib.hasSuffix "esac" b
    );

    # Nothing to inject ⇒ no gate at all (an env-only wrapper must stay a
    # transparent exec, not grow a dead `case`).
    module-kiro-wrapper-gate-empty-injection = mkTest "kiro-wrapper-gate-empty-injection" (
      idempotentFlags.gateOnSubcommand {subcommands = ["chat"];} "" == ""
    );

    # An empty accepted set can never fire, which would silently drop the
    # injection rather than fail — so it throws instead.
    module-kiro-wrapper-gate-rejects-empty-set = mkTest "kiro-wrapper-gate-rejects-empty-set" (!(builtins.tryEval (idempotentFlags.gateOnSubcommand {subcommands = [];} "INJECTED")).success);

    module-kiro-default-disabled = mkTest "kiro-default-disabled" (
      !(evalHm {}).config.ai.kiro.enable
      && !(evalDevenv {}).config.ai.kiro.enable
    );

    # Kiro HM keeps context in the `AGENTS.md` steering entry and emits each keyed
    # rule as `<name>.md` through the common runtime file map.
    module-kiro-hm-context-and-rules = mkTest "kiro-hm-context-and-rules" (
      let
        evaluated = evalHm {
          ai = {
            kiro = {
              enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules = {
                named-rule = {
                  matcher = ["src/**"];
                  text = "NAMED-RULE-BODY-TOKEN.";
                };
                unnamed.text = "UNNAMED-INSTR-TOKEN.";
              };
            };
          };
        };
        steering = kiroSteeringFiles evaluated;
        contextFile = (steering."AGENTS.md" or {}).text or "";
        unnamedFile = steering."unnamed.md" or null;
        namedFile = steering."named-rule.md" or null;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
        && unnamedFile != null
        && lib.hasInfix "UNNAMED-INSTR-TOKEN." (unnamedFile.text or "")
        && namedFile != null
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
    );

    # Kiro devenv shares repository-root AGENTS.md with Codex for context and
    # always-on rules; scoped rules remain native steering files.
    module-kiro-devenv-context-and-rules = mkTest "kiro-devenv-context-and-rules" (
      let
        evaluated = evalDevenv {
          ai = {
            kiro = {
              enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules = {
                named-rule = {
                  matcher = ["src/**"];
                  text = "NAMED-RULE-BODY-TOKEN.";
                };
                unnamed.text = "UNNAMED-INSTR-TOKEN.";
              };
            };
          };
        };
        steering = kiroSteeringFiles evaluated;
        contextFile = (evaluated.config.files."AGENTS.md" or {}).text or "";
        namedFile = steering."named-rule.md" or null;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile
        && !(steering ? "AGENTS.md")
        && namedFile != null
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
    );

    module-kiro-mcp-secret-placeholders = mkTest "kiro-mcp-secret-placeholders" (
      let
        mcpJson = renderedMcpJson {
          jira = {
            type = "http";
            url = {
              file = "/run/secrets/jira-url";
              prefix = "https://";
            };
            timeout = 300000;
            headers = {
              "X-MCP-Servers" = "jira";
              "X-Jira-Token".file = "/run/secrets/service-token";
              "X-Api-Key" = {
                file = "/run/secrets/llm";
                prefix = "Bearer ";
              };
            };
          };
        };
      in
        lib.hasInfix "\${env:KIRO_MCP_JIRA_X_JIRA_TOKEN}" mcpJson
        && lib.hasInfix "Bearer \${env:KIRO_MCP_JIRA_X_API_KEY}" mcpJson
        && lib.hasInfix "https://\${KIRO_MCP_JIRA_URL}" mcpJson
        && lib.hasInfix ''"X-MCP-Servers":"jira"'' mcpJson
        && !(lib.hasInfix "/run/secrets/service-token" mcpJson)
        && !(lib.hasInfix "/run/secrets/llm" mcpJson)
        && !(lib.hasInfix "/run/secrets/jira-url" mcpJson)
    );

    # ONE credential shared by TWO servers. A gateway that multiplexes several
    # backends behind a single endpoint produces this: each server carries its
    # own token and a routing header, but they authenticate with the SAME api
    # key. The shared key must collapse to a SINGLE export rather than tripping
    # the collision guard — that guard rejects one var bound to two DIFFERENT
    # sources, which is not this case.
    module-kiro-mcp-secret-shared-across-servers = mkTest "kiro-mcp-secret-shared-across-servers" (
      let
        sharedKey = {
          file = "/run/secrets/gateway-key";
          prefix = "Bearer ";
          var = "GW_KEY";
        };
        mkServer = route: tokenFile: tokenVar: {
          type = "http";
          url = "https://gateway.example.com/mcp/";
          headers = {
            "X-Api-Key" = sharedKey;
            "X-Route" = route;
            "X-Token" = {
              file = tokenFile;
              var = tokenVar;
            };
          };
        };
        result = renderKiroSecrets {
          alpha = mkServer "alpha" "/run/secrets/alpha-token" "ALPHA_TOKEN";
          beta = mkServer "beta" "/run/secrets/beta-token" "BETA_TOKEN";
        };
        rendered = builtins.toJSON result.servers;
      in
        # The shared key deduped to one export, the per-server tokens stayed distinct.
        (builtins.attrNames result.secretEnv)
        == ["ALPHA_TOKEN" "BETA_TOKEN" "GW_KEY"]
        && result.secretEnv.GW_KEY.file == "/run/secrets/gateway-key"
        # Both servers reference that one var, with the prefix composed per-server.
        && (builtins.length (builtins.filter
          (lib.hasInfix "Bearer \${env:GW_KEY}")
          (map builtins.toJSON (builtins.attrValues result.servers))))
        == 2
        # Plain routing headers pass through untouched; no secret path is serialized.
        && lib.hasInfix ''"X-Route":"beta"'' rendered
        && !(lib.hasInfix "/run/secrets/" rendered)
    );

    # An explicit `var` is user-supplied and lands verbatim in generated shell
    # (`export <var>=…`, and the envsubst variable list), so an illegal shell
    # identifier must fail at EVAL rather than produce a broken activation
    # script at the moment secrets are materialized. A DERIVED name cannot hit
    # this — `sanitize` builds it — so only the explicit path needs the guard.
    module-kiro-mcp-secret-illegal-var-throws = mkTest "kiro-mcp-secret-illegal-var-throws" (
      let
        renders = var:
          builtins.tryEval (builtins.toJSON
            (renderKiroSecrets {
              a = {
                type = "http";
                url = "https://a.example.com/mcp/";
                headers."X-Key" = {
                  file = "/run/secrets/one";
                  inherit var;
                };
              };
            })
          .secretEnv);
      in
        # Hyphen, space, and a leading digit are all rejected...
        !(renders "my-key").success
        && !(renders "my key").success
        && !(renders "1KEY").success
        # ...while a legal identifier still goes through.
        && (renders "MY_KEY_1").success
    );

    # The collision guard genuinely fires: the SAME var bound to two DIFFERENT
    # files is ambiguous (silent last-wins would export the wrong secret), so it
    # must throw rather than pick one. Guards the dedup above from being widened
    # into "same name always wins".
    module-kiro-mcp-secret-var-collision-throws = mkTest "kiro-mcp-secret-var-collision-throws" (!(builtins.tryEval (builtins.toJSON
      (renderKiroSecrets {
        a = {
          type = "http";
          url = "https://a.example.com/mcp/";
          headers."X-Key" = {
            file = "/run/secrets/one";
            var = "SHARED";
          };
        };
        b = {
          type = "http";
          url = "https://b.example.com/mcp/";
          headers."X-Key" = {
            file = "/run/secrets/two";
            var = "SHARED";
          };
        };
      })
      .secretEnv))
    .success);

    # Kiro HM<->devenv parity: the SAME config yields the SAME rendered
    # mcp.json template on both backends (identical content -> identical
    # store path), each delivered as a REAL file (HM activation / devenv
    # task anchored to $DEVENV_ROOT). Replaces the old home.file
    # symlink parity now that delivery is uniform real-file.
    module-kiro-hm-devenv-mcp-json-parity = mkTest "kiro-hm-devenv-mcp-json-parity" (
      let
        serversCfg = {
          jira = {
            type = "http";
            url.file = "/run/secrets/jira-url";
            headers."X-Jira-Token".file = "/run/secrets/service-token";
          };
        };
        cfg = {
          ai.kiro = {
            enable = true;
            mcpServers = serversCfg;
          };
        };
        dv = evalDevenv cfg;
        hmRender = (hmMcpDirTarget (evalHm cfg)).units."mcp.json".run;
        dvRender = (dvMcpDirTarget dv).units."mcp.json".run;
        # Same content -> same store path on both backends. Strip the
        # string context: `lib.hasInfix` compiles the needle into a
        # `builtins.match` regex, which rejects a store-path context.
        templatePath = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" (renderedMcpJson serversCfg)}";
      in
        lib.hasInfix templatePath hmRender
        && lib.hasInfix templatePath dvRender
        # The two render commands differ in ONE way, and it is the anchor: the
        # devenv task used to `cd "$DEVENV_ROOT"` before rendering, so a
        # relative credential path resolved against the project root there
        # while HM has always resolved against the activation's cwd. `own`
        # never `cd`s, so the renderer carries that anchor now, on the one
        # backend that had it.
        && hasLiteral ''cd "$NAT_OWN_ROOT"'' dvRender
        && !(hasLiteral "cd " hmRender)
        # Both plans name the same destination, each against its own root.
        && (hmMcpDirTarget (evalHm cfg)).path == (dvMcpDirTarget dv).path
        && hasLiteral ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' hmRender
        && hasLiteral ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' dvRender
    );

    # Kiro HM: a secret url makes mcp.json a REAL-file activation write (NOT
    # a home.file symlink) that exports the url secret, envsubst's ONLY the
    # url var (header ${env:...} survive), and locks the file read-only
    # (overwrite default + secret url -> owner-only 0400).
    module-kiro-hm-mcp-json-activation-secret-url = mkTest "kiro-hm-mcp-json-activation-secret-url" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.jira = {
              type = "http";
              url.file = "/run/secrets/jira-url";
              headers."X-Jira-Token".file = "/run/secrets/service-token";
            };
          };
        };
        target = hmMcpDirTarget result;
        unit = target.units."mcp.json";
        script = unit.run;
      in
        !(result.config.home.file ? ".kiro/settings/mcp.json")
        && target.path == ".kiro/settings"
        && lib.hasInfix ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' script
        && lib.hasInfix "/bin/envsubst '\${KIRO_MCP_JIRA_URL}'" script
        # The mode is DECLARED in the plan now, not an argument inside a
        # generated write call: owner-only, because this file holds the
        # substituted url secret.
        && unit.mode == "0400"
        # The secret read must be a BARE assignment whose status errexit can
        # see, then a separate `export`. `export VAR="$(cmd)"` returns export's
        # status (always 0), so a failed read is silent and envsubst writes
        # `"url": ""`. This assertion previously required that exact broken
        # form, which is how the bug shipped.
        && lib.hasInfix ''KIRO_MCP_JIRA_URL="$('' script
        && !(lib.hasInfix ''export KIRO_MCP_JIRA_URL="$('' script)
        && lib.hasInfix "export KIRO_MCP_JIRA_URL\n" script
        # A secret file that exists but is EMPTY reads successfully, so length
        # is checked too rather than trusting the exit status alone.
        && lib.hasInfix ''if [ -z "''${KIRO_MCP_JIRA_URL}" ]; then'' script
        # Scoped: HM concatenates every activation entry into one script, so an
        # unscoped strict-mode header leaks into later entries and HM's own
        # code, and the exported SECRET would stay live for the rest of
        # activation.
        && lib.hasPrefix "(\nset -euETo pipefail" script
        && lib.hasSuffix ")\n" script
    );

    # Kiro HM: a plain (non-secret) http server still lands as a real-file
    # overwrite write — locked world-readable 0444, no envsubst step.
    module-kiro-hm-mcp-json-plain-overwrite = mkTest "kiro-hm-mcp-json-plain-overwrite" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.plain = {
              type = "http";
              url = "https://gw/mcp/";
            };
          };
        };
        unit = (hmMcpDirTarget result).units."mcp.json";
      in
        unit.mode
        == "0444"
        && !(lib.hasInfix "envsubst" unit.run)
        && !(result.config.home.file ? ".kiro/settings/mcp.json")
    );

    # Merge owns leaves only: the document target declares the producer and the
    # directory target claims nothing, so the whole-file claim a previous
    # overwrite generation recorded is RELEASED rather than deleted.
    #
    # Both activation entries exist in this mode too, which is the shape change
    # the rework makes. There used to be a separate `retire-materialize-kiro-
    # settings` entry for exactly this release, and a prune entry only under
    # overwrite; `own` has one bundle, so the release happens in the prune
    # phase of the same pair. The prune entry is REQUIRED here, not optional:
    # the file it may have to hand over is a real file, and it must be gone (or
    # released) before checkLinkTargets.
    module-kiro-hm-mcp-json-merge-mode = mkTest "kiro-hm-mcp-json-merge-mode" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpWriteMode = "merge";
            mcpServers.plain = {
              type = "http";
              url = "https://gw/mcp/";
            };
          };
        };
        activation = result.config.home.activation;
      in
        (hmMcpDocTarget result).units
        ? "run"
        && (hmMcpDirTarget result).units == {}
        && (hmMcpDocTarget result).ledger == "json-settings/kiro-mcp-${builtins.hashString "sha256" ".kiro"}.json"
        && activation ? "materialize-kiro-settings-prune"
        && activation ? kiroMcpJson
        && !(activation ? "retire-materialize-kiro-settings")
    );

    # The N→0 regression: both backends keep their writer and their prune when
    # the last server disappears in overwrite mode. Disabled modules remain
    # inert. Non-empty pools are positive controls for the accessors.
    module-kiro-mcp-empty-pool-still-prunes = mkTest "kiro-mcp-empty-pool-still-prunes" (
      builtins.all (mode: let
        cfg = servers: {
          ai.kiro = {
            enable = true;
            mcpServers = servers;
            mcpWriteMode = mode;
          };
        };
        full = cfg {
          demo = {
            type = "http";
            url = "https://example.invalid/mcp";
          };
        };
        hmFull = evalHm full;
        hmEmpty = evalHm (cfg {});
        dvFull = evalDevenv full;
        dvEmpty = evalDevenv (cfg {});
        task = dvEmpty.config.tasks."ai:kiro:materialize-mcp" or {};
      in
        # Both phases are emitted for an empty pool, on both backends, against
        # the ledger the previous generation wrote — that is what makes N→0 a
        # retirement instead of a leak.
        lib.hasInfix "--phase all" (hmMcpWriteScript hmEmpty)
        && lib.hasInfix "--phase prune" (hmMcpPruneScript hmEmpty)
        && lib.hasInfix "--phase all" (dvMcpTaskExec dvEmpty)
        && ownPlanArg (hmMcpPruneScript hmEmpty) == ownPlanArg (hmMcpWriteScript hmEmpty)
        # The whole-file unit exists only for a NON-EMPTY overwrite pool, and
        # the ledger is the same literal in both cases.
        && (hmMcpDirTarget hmFull).units ? "mcp.json"
        && (dvMcpDirTarget dvFull).units ? "mcp.json"
        && (hmMcpDirTarget hmEmpty).units == {}
        && (dvMcpDirTarget dvEmpty).units == {}
        && builtins.all (target: target.ledger == "materialize/kiro-settings.manifest") [
          (hmMcpDirTarget hmFull)
          (hmMcpDirTarget hmEmpty)
          (dvMcpDirTarget dvFull)
          (dvMcpDirTarget dvEmpty)
        ]
        # The document target declares nothing under overwrite, which is what
        # makes an emptied overwrite DELETE the file rather than release it.
        && (hmMcpDocTarget hmEmpty).units == {}
        && lib.elem "sops-nix" hmFull.config.home.activation.kiroMcpJson.after
        && lib.elem "checkLinkTargets" hmEmpty.config.home.activation."materialize-kiro-settings-prune".before
        && lib.elem "devenv:enterShell" task.before
        && lib.elem "devenv:files:cleanup" task.after
        && !((evalHm {ai.kiro.enable = false;}).config.home.activation ? kiroMcpJson)
        && !((evalDevenv {ai.kiro.enable = false;}).config.tasks ? "ai:kiro:materialize-mcp"))
      ["overwrite"]
    );

    module-kiro-mcp-reconcile-runtime = import ./mcp-reconcile-runtime.nix {
      inherit lib pkgs harness;
    };

    module-kiro-materializer-entry-shapes = mkTest "kiro-materializer-entry-shapes" (
      let
        mat = import ../../../lib/ai/materialize.nix {inherit lib;};
        entry = {
          source = null;
          strategy = "copy";
          text = "static";
        };
        accepts = e:
          builtins.all (a: a.assertion) (mat.mkEntryAssertions {
            app = "kiro";
            files."mcp.json" = e;
            surface = "mcp";
          });
        rendered =
          entry
          // {
            text = null;
            renderCommand = "printf runtime";
          };
        typed =
          (lib.evalModules {
            modules = [
              {
                options.entry = lib.mkOption {type = mat.fileEntryType;};
                config.entry = rendered;
              }
            ];
          }).config.entry;
      in
        accepts entry
        && accepts rendered
        && accepts (rendered // {mode = "0400";})
        && typed.mode == "0444"
        && typed.renderCommand == "printf runtime"
        && !(accepts (entry // {text = null;}))
        && !(accepts (entry // {renderCommand = "printf duplicate";}))
        && !(accepts (rendered // {strategy = "symlink";}))
        && !(accepts (rendered // {mode = "0999";}))
    );

    # Execute the actual module writers against isolated roots. No Kiro
    # package build or invocation: only shell scripts, JSON templates and the
    # materializer's small tool closure. Replay HM prune then write.
    module-kiro-mcp-materialize-runtime = let
      mat = import ../../../lib/ai/materialize.nix {inherit lib;};
      plainUrl = "https://example.invalid/mcp";
      # Exercise the new generic renderer with output BEFORE failure. A
      # direct pipe to nat_mat_write would publish these partial bytes.
      failedRenderer =
        pkgs.writeShellScript "kiro-mcp-failed-renderer"
        (mat.mkDevenvTask {
          files."mcp.json" = {
            renderCommand = ''
              printf 'partial output'
              false
              printf 'unreachable'
            '';
            strategy = "copy";
          };
          hasFiles = false;
          stateSlug = "kiro-settings";
          targetDir = ".kiro/settings";
          inherit (pkgs) coreutils diffutils flock gnugrep;
        }).exec;
      cfg = mode: servers: {
        ai.kiro = {
          enable = true;
          mcpServers = servers;
          mcpWriteMode = mode;
        };
      };
      server = url: {
        demo = {
          type = "http";
          inherit url;
        };
      };
      mkScript = backend: config: let
        body =
          if backend == "hm"
          then let ev = evalHm config; in hmMcpPruneScript ev + "\n" + hmMcpWriteScript ev
          else dvMcpTaskExec (evalDevenv config);
      in
        pkgs.writeShellScript "kiro-mcp-${backend}" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${body}
        '';
      runBackend = backend: let
        script = mode: servers: mkScript backend (cfg mode servers);
        empty = script "overwrite" {};
        plain = script "overwrite" (server plainUrl);
        secret = script "overwrite" (server {file = "credential-url";});
        failedHelper = script "overwrite" (server {helper = "./failed-helper";});
      in ''
        export HOME="$TMPDIR/${backend}-home"
        export XDG_STATE_HOME="$TMPDIR/${backend}-state"
        export DEVENV_ROOT="$HOME"
        export DEVENV_STATE="$XDG_STATE_HOME"
        mkdir -p "$HOME/.kiro/settings" "$HOME/subdir"
        cd "$HOME"
        target="$HOME/.kiro/settings/mcp.json"
        ledger="$XDG_STATE_HOME/nix-agentic-tools/materialize"
        manifest="$ledger/kiro-settings.manifest"
        backups="$ledger/kiro-settings.bak"

        # Empty-first must preserve a foreign file and its neighbors.
        printf '{"mcpServers":{"hand":{"url":"https://hand.invalid"}}}\n' > "$target"
        cp "$target" original
        printf 'neighbor\n' > "$HOME/.kiro/settings/unmanaged.json"
        ${empty}
        cmp original "$target" || fail '${backend}: empty pool clobbered an unmanaged file'
        [ ! -s "$manifest" ] || fail '${backend}: empty pool claimed an unmanaged file'

        # Adoption backs up, and the manifest hashes the rendered bytes.
        ${plain}
        [ ! -L "$target" ] || fail '${backend}: managed file is a symlink'
        [ "$(stat -c %a "$target")" = 444 ] || fail '${backend}: default mode'
        cmp original "$backups"/mcp.json.* || fail '${backend}: adoption backup'
        [ "$(cut -f 2 "$manifest")" = "$(sha256sum "$target" | cut -d ' ' -f 1)" ] \
          || fail '${backend}: manifest did not hash actual content'
        touch -t 200001010000 "$target"
        before_mtime="$(stat -c %Y "$target")"
        ${plain}
        [ "$(stat -c %Y "$target")" = "$before_mtime" ] || fail '${backend}: identical content changed mtime'

        # Identical rendered bytes must still tighten and loosen permissions.
        printf '%s' '${plainUrl}' > credential-url
        ${secret}
        [ "$(stat -c %a "$target")" = 400 ] || fail '${backend}: unchanged secret mode'
        ${plain}
        [ "$(stat -c %a "$target")" = 444 ] || fail '${backend}: unchanged plain mode'

        # A failing or empty credential must leave target AND manifest intact.
        cp "$target" before-target
        cp "$manifest" before-manifest
        rm credential-url
        expect_failure ${secret}
        : > credential-url
        expect_failure ${secret}
        cat > failed-helper <<'HELPER'
        #!${pkgs.runtimeShell}
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'partial-secret'
        false
        HELPER
        chmod +x failed-helper
        expect_failure ${failedHelper}
        expect_failure ${failedRenderer}

        # Emptying the pool removes only the owned file. A later foreign file
        # with that name is preserved because the manifest has been drained.
        ${empty}
        [ ! -e "$target" ] || fail '${backend}: N to zero did not prune'
        [ ! -s "$manifest" ] || fail '${backend}: manifest was not drained'
        cp original "$target"
        ${empty}
        cmp original "$target" || fail '${backend}: drained ownership still clobbered'

        # Merge retirement and permissions have their own leaf-ownership
        # corpus. Keep this whole-file corpus's overwrite checks unchanged.
        rm "$target"
        [ "$(cat "$HOME/.kiro/settings/unmanaged.json")" = neighbor ] || fail '${backend}: neighbor changed'

        # Non-regular collisions must fail without falsely claiming ownership.
        # The ledger was drained two steps above, and a drained ledger is now
        # ABSENT rather than a zero-byte file, so "not claimed" is asserted as
        # absence: a claim would write a line naming mcp.json.
        mkdir "$target"
        [ ! -e "$manifest" ] || fail '${backend}: drained ledger still on disk'
        if ${plain}; then fail '${backend}: directory collision succeeded'; fi
        [ -d "$target" ] || fail '${backend}: directory collision was removed'
        [ ! -e "$manifest" ] || fail '${backend}: directory was claimed'
        rmdir "$target"

        # Writes must be anchored from any cwd: the HM activation inherits
        # whatever directory `home-manager switch` ran in, and devenv runs a
        # task in the CALLER's directory because direnv activates in
        # subdirectories. Neither writer `cd`s any more.
        cd "$HOME/subdir"
        ${plain}
        [ -f "$target" ] || fail '${backend}: root anchoring failed'
        [ ! -e .kiro ] || fail '${backend}: wrote under caller cwd'
        ${lib.optionalString (backend == "devenv") ''
          # A RELATIVE credential path resolved against the project root while
          # the task still ran `cd "$DEVENV_ROOT"`; the renderer carries that
          # anchor now, so prove it from a foreign cwd with the secret present
          # only at the project root.
          printf '%s' '${plainUrl}' > "$DEVENV_ROOT/credential-url"
          ${secret}
          [ "$(stat -c %a "$target")" = 400 ] || fail '${backend}: anchored secret mode'
          [ ! -e credential-url ] || fail '${backend}: read a credential from the caller cwd'
        ''}
      '';
    in
      pkgs.runCommand "module-test-kiro-mcp-materialize-runtime" {} ''
        fail() { echo "FAIL: kiro-mcp-materialize-runtime: $1" >&2; exit 1; }
        expect_failure() {
          if "$1"; then fail 'credential failure unexpectedly succeeded'; fi
          cmp before-target "$target" || fail 'failed render replaced target'
          cmp before-manifest "$manifest" || fail 'failed render advanced manifest'
        for temporary in "$HOME/.kiro/settings/".*.nat-tmp.*; do
          [ ! -e "$temporary" ] || fail 'failed render left a credential temporary file'
        done
        }
        ${lib.concatMapStrings runBackend ["hm" "devenv"]}
        echo 'PASS: kiro-mcp-materialize-runtime' > "$out"
      '';

    # ── Task 5 (A4): Kiro HM/devenv fanout absorption ────────────

    # HM: package installation — verify home.packages populated.
    module-kiro-hm-wraps-package = mkTest "kiro-hm-wraps-package" (
      let
        result = evalHm {
          ai.kiro.enable = true;
        };
        packages = result.config.home.packages;
      in
        builtins.length packages >= 1
    );

    # HM: settings activation owns leaves and carries the declared content.
    # The content is read from `_reconciledDocuments`, not from the activation
    # body: the reconciler carries it as data in a store plan. The ledger path
    # is asserted because it is the live migration contract every previously
    # written ownership record hangs off.
    module-kiro-hm-empty-settings-emits-writer = mkTest "kiro-hm-empty-settings-emits-writer" (
      let
        evaluated = evalHm {ai.kiro.enable = true;};
      in
        lib.hasInfix "--phase all" evaluated.config.home.activation.kiroSettingsMerge.text
        && lib.hasPrefix "json-settings/kiro-settings-" (cliDocument evaluated).ledger
        && (cliDocument evaluated).value == {}
    );

    module-kiro-hm-writes-settings-activation = mkTest "kiro-hm-writes-settings-activation" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.defaultModel = "claude-sonnet-4";
          };
        };
      in
        lib.hasInfix "--phase all" result.config.home.activation.kiroSettingsMerge.text
        && (cliDocument result).value."chat.defaultModel" == "claude-sonnet-4"
    );

    # Known Kiro model id reaches the cli.json merge.
    module-kiro-hm-default-model-known-accepted = mkTest "kiro-hm-default-model-known-accepted" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.defaultModel = "claude-opus-4.8";
          };
        };
      in
        (cliDocument result).value."chat.defaultModel" == "claude-opus-4.8"
    );

    # Arbitrary (unknown) id is accepted (str branch of the soft enum).
    module-kiro-hm-default-model-arbitrary-accepted = mkTest "kiro-hm-default-model-arbitrary-accepted" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.defaultModel = "some-future-model";
          };
        };
      in
        (cliDocument result).value."chat.defaultModel" == "some-future-model"
    );

    # v3 = true triggers the HM wrapper (appends --v3 to the launcher).
    # Stub can't introspect postBuild, but a named symlinkJoin
    # ("kiro-cli-wrapped") is a strong signal the wrapper fired — same
    # fidelity as the copilot wrapper tests.
    module-kiro-hm-v3-wraps-package = mkTest "kiro-hm-v3-wraps-package" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        };
        packages = result.config.home.packages;
      in
        lib.any (p: p.name == "kiro-cli-wrapped") packages
    );

    # The `tui` option is GONE. It injected `--tui` and implied `--v3`; `--tui`
    # is redundant under v3 and is going away with it. Setting it must now be a
    # hard eval error, not a silently-ignored key — otherwise a stale consumer
    # config looks accepted while quietly losing the engine flag it depended on.
    module-kiro-hm-tui-option-removed = mkTest "kiro-hm-tui-option-removed" (!(builtins.tryEval
      (evalHm {
        ai.kiro = {
          enable = true;
          tui = true;
        };
      })
      .config
      .home
      .packages)
    .success);

    # The unlock must FORK the derivation — if the drvPath were unchanged, the
    # patch step silently did nothing and the consumer would get stock kiro while
    # believing workflows were on. Comparing drvPaths is the only assertion that
    # actually distinguishes those two worlds; a name check cannot, because both
    # sides are named `kiro-cli-wrapped`.
    module-kiro-hm-rollout-unlock-forks-package = mkTest "kiro-hm-rollout-unlock-forks-package" (
      let
        a =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
            };
          })
      .config
      .home
      .packages or [
          ];
        b =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = ["workflows"];
            };
          })
      .config
      .home
      .packages or [
          ];
      in
        soleFork a b
    );

    # devenv parity: same fork, same option, same backend-independent result.
    module-kiro-devenv-rollout-unlock-forks-package = mkTest "kiro-devenv-rollout-unlock-forks-package" (
      let
        a =
          kiroWrappedDrvs
          (evalDevenv {
            ai.kiro = {
              enable = true;
              v3 = true;
            };
          })
      .config
      .packages or [
          ];
        b =
          kiroWrappedDrvs
          (evalDevenv {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = ["workflows"];
            };
          })
      .config
      .packages or [
          ];
      in
        soleFork a b
    );

    # The default MUST leave the package untouched. This is what protects every
    # cachix hit: an unconditional patch step would fork the drvPath for every
    # consumer, including those who never asked for a dark-shipped feature.
    module-kiro-rollout-default-is-stock = mkTest "kiro-rollout-default-is-stock" (
      let
        packages = (evalHm {ai.kiro.enable = true;}).config.home.packages;
      in
        lib.any (p: (p.drvPath or null) == pkgs.ai.kiro-cli.drvPath) packages
    );

    # A duplicated entry must NOT fork the derivation — otherwise two configs
    # that mean the same thing produce two store paths and two 556 MB builds.
    module-kiro-rollout-dedupes-features = mkTest "kiro-rollout-dedupes-features" (
      let
        drvOf = features:
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = features;
            };
          })
        .config
        .home
        .packages or [
          ];
      in
        soleSame (drvOf ["workflows"]) (drvOf ["workflows" "workflows"])
        # Order must not fork it either. The list is comma-joined into
        # `postFixup`, so without a sort these two semantically identical sets
        # would produce different drvPaths and two redundant ~556 MB builds.
        && soleSame (drvOf ["tangent" "workflows"]) (drvOf ["workflows" "tangent"])
        # Control: a genuinely DIFFERENT set must still fork. Without this, the
        # two assertions above would also pass if canonicalization had collapsed
        # every input to a single derivation.
        && soleFork (drvOf ["workflows"]) (drvOf ["tangent" "workflows"])
    );

    # A `package` without the overlay's passthru cannot be patched. Assert the
    # failure is the NAMED one rather than a bare "attribute missing" pointing
    # into factory internals.
    module-kiro-rollout-rejects-package-without-passthru = mkTest "kiro-rollout-rejects-package-without-passthru" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            package = pkgs.hello;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Positive control for the above — the same assertion must PASS on the
    # overlay-provided package, or the negative proves only that it always fires.
    module-kiro-rollout-accepts-overlay-package = mkTest "kiro-rollout-accepts-overlay-package" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == true
    );

    # The FHS compatibility wrapper remains the default. Opting out selects the
    # overlay's pinned payload rather than a second independently packaged Kiro.
    module-kiro-hm-fhs-opt-out-selects-unwrapped = mkTest "kiro-hm-fhs-opt-out-selects-unwrapped" (
      let
        result = evalHm {
          ai.gitSshConfigWorkaround = false;
          ai.kiro = {
            enable = true;
            useFhsSandbox = false;
          };
        };
        packages = result.config.home.packages;
      in
        builtins.length packages
        == 1
        && (builtins.head packages).drvPath == pkgs.ai.kiro-cli.unwrapped.drvPath
    );

    # Devenv shares the same option and package-selection seam.
    module-kiro-devenv-fhs-opt-out-selects-unwrapped = mkTest "kiro-devenv-fhs-opt-out-selects-unwrapped" (
      let
        result = evalDevenv {
          ai.gitSshConfigWorkaround = false;
          ai.kiro = {
            enable = true;
            useFhsSandbox = false;
          };
        };
        packages = result.config.packages;
      in
        builtins.length packages
        == 1
        && (builtins.head packages).drvPath == pkgs.ai.kiro-cli.unwrapped.drvPath
    );

    # When another option still requires a wrapper, the opt-out must change the
    # wrapper's exec target rather than merely changing the empty-wrapper case.
    # Devenv's default Git SSH export supplies that production-shaped wrapper.
    module-kiro-devenv-fhs-opt-out-wrapper-targets-unwrapped = let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          useFhsSandbox = false;
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-fhs-opt-out-wrapper-targets-unwrapped";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli"];
        absentNeedles = ["${pkgs.ai.kiro-cli}/bin/kiro-cli"];
      };

    # #956's exact backend: with no unrelated wrapper reason, trustedMcpTools
    # must fork the FHS payload itself. The former outer symlinkJoin had no
    # `fhsenv` passthru and was unreachable during launcher dispatch.
    module-kiro-devenv-trusted-tools-fork-fhs-payload = mkTest "kiro-devenv-trusted-tools-fork-fhs-payload" (
      let
        result = evalDevenv {
          ai.gitSshConfigWorkaround = false;
          ai.kiro = {
            enable = true;
            trustedMcpTools = ["fs_read"];
          };
        };
        packages = result.config.packages;
        configured = builtins.head packages;
      in
        builtins.length packages
        == 1
        && configured ? fhsenv
        && configured.fhsenv.drvPath != pkgs.ai.kiro-cli.fhsenv.drvPath
        && configured.name != "kiro-cli-wrapped"
    );

    # A custom package without a supported unwrapped route must fail by the
    # named assertion instead of silently leaving the FHS wrapper enabled.
    module-kiro-fhs-opt-out-rejects-package-without-unwrapped = mkTest "kiro-fhs-opt-out-rejects-package-without-unwrapped" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            package = pkgs.hello;
            useFhsSandbox = false;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.unwrapped" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Positive control: the overlay package exposes the route and satisfies the
    # same assertion when the opt-out is selected.
    module-kiro-fhs-opt-out-accepts-overlay-package = mkTest "kiro-fhs-opt-out-accepts-overlay-package" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            useFhsSandbox = false;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.unwrapped" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == true
    );

    # The supported pre-split topology is already unwrapped. Its explicit false
    # marker makes opt-out a valid no-op instead of confusing the public
    # `unwrapped` route with evidence that an FHS composition seam is missing.
    module-kiro-fhs-opt-out-accepts-pre-split-contract = mkTest "kiro-fhs-opt-out-accepts-pre-split-contract" (
      let
        preSplitPackage = pkgs.hello.overrideAttrs (attrs: {
          passthru =
            (attrs.passthru or {})
            // {
              kiroFhsSandbox = false;
              unwrapped = pkgs.hello;
            };
        });
        ev = evalHm {
          ai.kiro = {
            enable = true;
            package = preSplitPackage;
            useFhsSandbox = false;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.unwrapped" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == true
    );

    # A detectable custom FHS package without the payload-composition seam would
    # recreate #956. Reject it rather than silently leaving trust injection in an
    # outer wrapper that launcher dispatch cannot reach.
    module-kiro-trust-rejects-fhs-package-without-payload-seam = mkTest "kiro-trust-rejects-fhs-package-without-payload-seam" (
      if !pkgs.stdenv.hostPlatform.isLinux
      then true
      else let
        customFhsPackage = pkgs.hello.overrideAttrs (attrs: {
          passthru = (attrs.passthru or {}) // {unwrapped = pkgs.hello;};
        });
        ev = evalDevenv {
          ai.kiro = {
            enable = true;
            package = customFhsPackage;
            trustedMcpTools = ["fs_read"];
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.withFhsPayload" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Assertions inspect the resolved rollout variant, not merely cfg.package.
    # A custom factory that drops the FHS passthru contract must fail by name
    # before wrapping can silently retain the sandbox or lose trust injection.
    module-kiro-trust-rejects-rollout-variant-without-payload-seam = mkTest "kiro-trust-rejects-rollout-variant-without-payload-seam" (
      if !pkgs.stdenv.hostPlatform.isLinux
      then true
      else let
        customFhsPackage = pkgs.hello.overrideAttrs (attrs: {
          passthru =
            (attrs.passthru or {})
            // {
              kiroFhsSandbox = true;
              unwrapped = pkgs.hello;
              withFhsPayload = _: pkgs.hello;
              withRolloutFeatures = _: pkgs.hello;
            };
        });
        ev = evalHm {
          ai.kiro = {
            enable = true;
            package = customFhsPackage;
            trustedMcpTools = ["fs_read"];
            unlockedRolloutFeatures = ["workflows"];
            v3 = true;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.withFhsPayload" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # `unlockedRolloutFeatures` without `v3` is INERT, and silently so — the
    # binary really is patched, the option really is set, and the feature never
    # appears. The assertion is all that stands between a consumer and a
    # debugging session, so pin that it actually fires.
    module-kiro-rollout-requires-v3 = mkTest "kiro-rollout-requires-v3" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Positive control: the SAME assertion must pass once v3 is set, or the
    # negative above would hold equally for an assertion that always fires.
    module-kiro-rollout-v3-satisfies-assertion = mkTest "kiro-rollout-v3-satisfies-assertion" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == true
    );

    # Guards the sidecar wiring end to end: the option's enum is read from the
    # committed extraction, so an empty or malformed `rolloutFeatures` key would
    # otherwise surface only as a confusing type error at the consumer.
    module-kiro-rollout-enum-from-sidecar = mkTest "kiro-rollout-enum-from-sidecar" (
      let
        extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
      in
        lib.elem "workflows" extracted.rolloutFeatures
        && lib.elem "tangent" extracted.rolloutFeatures
        && builtins.length extracted.rolloutFeatures >= 6
    );

    # ── workflows: the SECOND gate ─────────────────────────────────────────────
    # `unlockedRolloutFeatures = ["workflows"]` patches the binary, which since
    # kiro-cli 2.19.0 only makes the feature AVAILABLE. The client also reads
    # `chat.enableWorkflows`, default false, so the unlock alone is silently
    # inert. HM implies the setting with the unlock; these pin that it happens,
    # that an explicit value still beats it, and that it does NOT happen where the
    # setting cannot work.
    module-kiro-workflows-unlock-implies-setting = mkTest "kiro-workflows-unlock-implies-setting" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
      in
        ev.config.ai.kiro.nativeSettings.chat.enableWorkflows == true
    );

    # The implication is a DEFAULT, not a mandate. Without `mkDefault` this would
    # be a definition conflict rather than a losing contribution, so the explicit
    # `false` is the only thing that distinguishes the two.
    module-kiro-workflows-explicit-setting-beats-unlock = mkTest "kiro-workflows-explicit-setting-beats-unlock" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
            nativeSettings.chat.enableWorkflows = false;
          };
        };
      in
        ev.config.ai.kiro.nativeSettings.chat.enableWorkflows == false
    );

    # Positive control for the two above: without the unlock nothing writes the
    # key, so a test that merely found `true` everywhere would be vacuous.
    module-kiro-workflows-no-unlock-leaves-setting-unset = mkTest "kiro-workflows-no-unlock-leaves-setting-unset" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        };
      in
        ev.config.ai.kiro.nativeSettings.chat.enableWorkflows == null
    );

    # devenv must NOT inherit the implication: it writes the project-local
    # cli.json, where kiro discards this key, so implying it there would both
    # mislead the consumer and trip the workspace-allowlist assertion below on a
    # config nobody wrote.
    module-kiro-devenv-workflows-unlock-implies-nothing = mkTest "kiro-devenv-workflows-unlock-implies-nothing" (
      let
        ev = evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        };
      in
        ev.config.ai.kiro.nativeSettings.chat.enableWorkflows
        == null
        && builtins.all (a: a.assertion) ev.config.assertions
    );

    # ── flatten boundary: object-valued settings ───────────────────────────────
    # cli.json is flat dotted keys whose VALUES may be objects, and attrset shape
    # alone cannot say where the key stops. Before the boundary these emitted
    # `chat.modelDefaults.claude-opus-5.effort`, which kiro never matches, so the
    # setting was unusable from Nix on BOTH backends.
    module-kiro-devenv-object-valued-setting-stays-nested = mkTest "kiro-devenv-object-valued-setting-stays-nested" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.modelDefaults."claude-opus-5".effort = "high";
          };
        };
        text = (result.config.files.".kiro/settings/cli.json" or {}).text or "";
      in
        lib.hasInfix ''"chat.modelDefaults":{"claude-opus-5":{"effort":"high"}}'' text
        && !lib.hasInfix "chat.modelDefaults.claude-opus-5" text
        # It is an allowlisted key, so the workspace guard must stay silent —
        # otherwise this would pass while the config was still rejected.
        && builtins.all (a: a.assertion) result.config.assertions
    );

    # Parity: the HM activation merge carries the same nesting. Both backends
    # share one `flattenKiroSettings`, and this is what pins that they do.
    module-kiro-hm-object-valued-setting-stays-nested = mkTest "kiro-hm-object-valued-setting-stays-nested" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.modelDefaults."claude-opus-5".effort = "high";
          };
        };
        declared = (cliDocument result).value;
      in
        declared."chat.modelDefaults"."claude-opus-5".effort
        == "high"
        && !(declared ? "chat.modelDefaults.claude-opus-5")
        && !(declared ? chat)
    );

    # Control: the boundary must stop the walk only AT a known key, never before
    # it. Without this, a flattener that gave up at depth one would pass both
    # tests above while writing nested `{"chat":{...}}` that kiro cannot read.
    module-kiro-scalar-setting-still-flattens = mkTest "kiro-scalar-setting-still-flattens" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            nativeSettings.chat.enableTangentMode = true;
          };
        };
        text = (result.config.files.".kiro/settings/cli.json" or {}).text or "";
      in
        lib.hasInfix ''"chat.enableTangentMode":true'' text
        && !lib.hasInfix ''"chat":{'' text
    );

    # ── workspace-settings allowlist (devenv only) ─────────────────────────────
    # A global-only key written to the project-local cli.json is read and dropped
    # by kiro with no warning, so the module refuses it instead of emitting a file
    # that looks applied.
    module-kiro-devenv-rejects-global-only-setting = mkTest "kiro-devenv-rejects-global-only-setting" (
      let
        ev = evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            nativeSettings.chat.enableWorkflows = true;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "silently discarded at runtime" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Positive control: an ALLOWLISTED key must sail through the same guard, or
    # the negative above would hold equally for an assertion that always fires.
    module-kiro-devenv-accepts-workspace-setting = mkTest "kiro-devenv-accepts-workspace-setting" (
      let
        ev = evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            nativeSettings.chat.enableTangentMode = true;
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "silently discarded at runtime" a.message)
          ev.config.assertions;
      in
        asserts == [] && builtins.all (a: a.assertion) ev.config.assertions
    );

    # The HM backend writes the GLOBAL file, where every key is honored. The same
    # config that fails under devenv must pass here, or the guard has leaked out
    # of the backend that owns it.
    module-kiro-hm-accepts-global-only-setting = mkTest "kiro-hm-accepts-global-only-setting" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            nativeSettings.chat.enableWorkflows = true;
          };
        };
      in
        builtins.all (a: a.assertion) ev.config.assertions
    );

    # No boundary key may be a strict dotted PREFIX of another. If one ever is, the walk stops at the SHORTER key and
    # writes nested JSON kiro cannot read — the exact defect the boundary fixed,
    # reintroduced by data rather than by code, and invisible to every other test
    # here because `module-kiro-scalar-setting-still-flattens` uses `chat`, which
    # is never terminal, so it never engages the boundary at all.
    #
    # `chat.tools` is the live candidate: `chat.tools.*` is already eleven
    # registry entries, so upstream naming the parent would trip this.
    module-kiro-flatten-boundary-has-no-prefix-pairs = mkTest "kiro-flatten-boundary-has-no-prefix-pairs" (
      let
        extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
        keys = lib.unique (extracted.settingKeys ++ extracted.workspaceOverridableSettings);
        nested =
          builtins.filter (
            a: builtins.any (b: a != b && lib.hasPrefix "${a}." b) keys
          )
          keys;
      in
        nested == []
    );

    # Sidecar WIRING: that the field exists, parses, and says what the devenv
    # assertion assumes about the pinned binary. It is NOT a test of the
    # extractor — it reads a committed list of strings and runs none of that
    # code, so it cannot tell a key resolved through the symbolic registry from
    # one that was always a literal. `checks/kiro-workspace-settings-fixtures`
    # drives the real script and is where the extraction paths are controlled.
    #
    # Every content claim is gated on the list being NON-EMPTY, and that gate is
    # load-bearing rather than defensive. An empty allowlist is a legitimate
    # answer — no kiro before 2.21.1 merges a workspace cli.json at all — and the
    # whole reason the extractor does not hard-fail on absence is that a pin back
    # to such a release must not wedge the pipeline. A bare `length >= 10` here
    # would have re-imposed exactly that wedge one layer up.
    #
    # The absence check is deliberate and is the fact the devenv assertion's whole
    # message rests on: if upstream ever adds `chat.enableWorkflows` to the
    # allowlist, this failing is the signal to relax that guidance rather than a
    # defect to route around.
    module-kiro-workspace-allowlist-from-sidecar = mkTest "kiro-workspace-allowlist-from-sidecar" (
      let
        extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
        allowlist = extracted.workspaceOverridableSettings;
      in
        builtins.isList allowlist
        # The flatten boundary rides the same sidecar. `chat.modelDefaults` is the
        # object-valued key the boundary exists for, so its presence is what makes
        # the nesting tests above more than a coincidence of the current data.
        && lib.elem "chat.modelDefaults" extracted.settingKeys
        && lib.elem "chat.enableWorkflows" extracted.settingKeys
        && builtins.length extracted.settingKeys >= 20
        && !(lib.elem "chat.enableWorkflows" allowlist)
        && (
          allowlist
          == []
          || (
            lib.elem "chat.enableTangentMode" allowlist
            && lib.elem "chat.defaultModel" allowlist
            && builtins.length allowlist >= 10
          )
        )
    );

    # ── identity ───────────────────────────────────────────────────────────────
    # Same drvPath discipline as the rollout tests above, and for the same reason:
    # both sides are named `kiro-cli-wrapped`, so a name check cannot tell a
    # patched launcher from an unpatched one and would pass VACUOUSLY.
    module-kiro-hm-identity-forks-package = mkTest "kiro-hm-identity-forks-package" (
      let
        a =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
            };
          })
        .config
        .home
        .packages or [
          ];
        b =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              identity.text = "You are Atlas, a senior systems engineer.";
            };
          })
        .config
        .home
        .packages or [
          ];
      in
        soleFork a b
    );

    # devenv parity: the materializer is threaded through the SHARED
    # `resolveIdentityMaterializer`, so a fork here proves both backends wire it.
    module-kiro-devenv-identity-forks-package = mkTest "kiro-devenv-identity-forks-package" (
      let
        a =
          kiroWrappedDrvs
          (evalDevenv {
            ai.kiro = {
              enable = true;
              v3 = true;
            };
          })
        .config
        .packages or [
          ];
        b =
          kiroWrappedDrvs
          (evalDevenv {
            ai.kiro = {
              enable = true;
              v3 = true;
              identity.text = "You are Atlas, a senior systems engineer.";
            };
          })
        .config
        .packages or [
          ];
      in
        soleFork a b
    );

    # The default must stay byte-identical to stock. An option that silently
    # wrapped every consumer would cost the cache hit it exists to preserve.
    module-kiro-identity-default-is-stock = mkTest "kiro-identity-default-is-stock" (
      let
        a =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
            };
          })
        .config
        .home
        .packages or [
          ];
        b =
          kiroWrappedDrvs
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              identity.enable = false;
            };
          })
        .config
        .home
        .packages or [
          ];
      in
        soleSame a b
    );

    # The splice re-joins the preserved vendor text directly after the
    # replacement, so an identity that does not close its own final sentence
    # MERGES into it. Caught at EVAL rather than by the splicer's backstop,
    # because the splicer runs on a FAIL-OPEN launch path — a value rejected
    # there presents as "the identity silently did nothing", which is the exact
    # shape that let a multi-sentence identity ship broken.
    module-kiro-identity-requires-sentence-punctuation = mkTest "kiro-identity-requires-sentence-punctuation" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            identity.text = "You are Atlas, a senior systems engineer";
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "must end with sentence punctuation" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # Positive control: the same assertion must PASS on a punctuated value, and
    # on `!`/`?` as well as `.`. Without this the test above passes for a config
    # that fails every assertion, including for unrelated reasons.
    module-kiro-identity-punctuation-accepts-terminators = mkTest "kiro-identity-punctuation-accepts-terminators" (
      let
        failing = ident: let
          ev = evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              identity.text = ident;
            };
          };
        in
          builtins.filter
          (a: lib.hasInfix "must end with sentence punctuation" a.message && !a.assertion)
          ev.config.assertions;
      in
        failing "You are Atlas, a senior systems engineer."
        == []
        && failing "You are Atlas! You judge silently." == []
        && failing "Are you sure about that?" == []
    );

    # ── workflow reminder ──────────────────────────────────────────────────────
    # AUTO means "on iff workflows is unlocked". All four corners of the tri-state
    # are pinned, because null/true/false is exactly where an off-by-default and
    # an on-by-default implementation look identical from any single test.
    module-kiro-workflow-reminder-auto-on-with-workflows = mkTest "kiro-workflow-reminder-auto-on-with-workflows" (
      let
        hooks =
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = ["workflows"];
            };
          })
        .config
        .ai
        .kiro
        .hooks;
      in
        hooks ? workflow-reminder
        && hooks.workflow-reminder.trigger == "UserPromptSubmit"
        # `agent` is the no-subprocess action: the short reminder is a static
        # string, so it needs no script and ignores timeout.
        && hooks.workflow-reminder.action.type == "agent"
        && hooks.workflow-reminder.action.prompt.enable
        && hooks.workflow-reminder.action.prompt.text != ""
    );

    module-kiro-workflow-reminder-absent-without-workflows =
      mkTest "kiro-workflow-reminder-absent-without-workflows" (!((evalHm {
        ai.kiro = {
          enable = true;
          v3 = true;
        };
      })
      .config
      .ai
      .kiro
      .hooks
      ? workflow-reminder));

    # Explicit `false` must beat the auto-on inference.
    module-kiro-workflow-reminder-forced-off =
      mkTest "kiro-workflow-reminder-forced-off" (!((evalHm {
        ai.kiro = {
          enable = true;
          v3 = true;
          unlockedRolloutFeatures = ["workflows"];
          workflowReminder.enable = false;
        };
      })
      .config
      .ai
      .kiro
      .hooks
      ? workflow-reminder));

    # Explicit `true` must beat the auto-off inference — the reminder is still
    # useful on a build where workflows were unlocked by some path other than
    # this option (KIRO_ENABLED_FEATURES, say).
    module-kiro-workflow-reminder-forced-on =
      mkTest "kiro-workflow-reminder-forced-on" (
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            workflowReminder.enable = true;
          };
        })
    .config
    .ai
    .kiro
    .hooks
    ? workflow-reminder
      );

    # The vendor-steering variant CANNOT be an `agent` action: its text lives in
    # the runtime-unpacked engine bundle, so it is not knowable at eval time and
    # has to shell out.
    module-kiro-workflow-reminder-vendor-steering-is-command = mkTest "kiro-workflow-reminder-vendor-steering-is-command" (
      let
        hook =
          (evalHm {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = ["workflows"];
              workflowReminder.includeVendorSteering = true;
            };
          })
        .config
        .ai
        .kiro
        .hooks
        .workflow-reminder;
      in
        hook.action.type == "command" && hook.action.command != null
    );

    # devenv parity for the reminder: same option, same contributed record.
    module-kiro-devenv-workflow-reminder-parity = mkTest "kiro-devenv-workflow-reminder-parity" (
      let
        hooks =
          (evalDevenv {
            ai.kiro = {
              enable = true;
              v3 = true;
              unlockedRolloutFeatures = ["workflows"];
            };
          })
        .config
        .ai
        .kiro
        .hooks;
      in
        hooks ? workflow-reminder && hooks.workflow-reminder.action.type == "agent"
    );

    # Devenv parity: v3 must wrap here too. Disable the Git SSH default so v3 is
    # the sole wrapper reason; otherwise this passes vacuously on the environment
    # export even if the flag wiring disappears.
    module-kiro-devenv-v3-wraps-package = mkTest "kiro-devenv-v3-wraps-package" (
      let
        result = evalDevenv {
          ai.gitSshConfigWorkaround = false;
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        };
        packages = result.config.packages;
      in
        lib.any (p: p.name == "kiro-cli-wrapped") packages
    );

    # devenv parity for the removal: the option must be absent on both backends.
    module-kiro-devenv-tui-option-removed = mkTest "kiro-devenv-tui-option-removed" (!(builtins.tryEval
      (evalDevenv {
        ai.kiro = {
          enable = true;
          tui = true;
        };
      })
      .config
      .packages)
    .success);

    # devenv: with no v3/trust and no env, the package is installed RAW (the
    # shared wrapper returns the unwrapped derivation — no needless symlinkJoin).
    # Opts out of `gitSshConfigWorkaround`: on devenv that default reaches Kiro
    # through `environmentVariables`, which is itself a reason to wrap. Leaving
    # it on would make this pass or fail on the SSH default rather than on the
    # wrapper gate it exists to test.
    module-kiro-devenv-no-flags-no-wrap = mkTest "kiro-devenv-no-flags-no-wrap" (
      let
        result = evalDevenv {
          ai.kiro.enable = true;
          ai.gitSshConfigWorkaround = false;
        };
        packages = result.config.packages;
      in
        builtins.length packages
        == 1
        && (builtins.head packages).drvPath == result.config.ai.kiro.package.drvPath
        && !(lib.any (p: p.name == "kiro-cli-wrapped") packages)
    );

    # HM: mcp.json — mergedServers deliver via a real-file activation write
    # (uniform real-file; no home.file symlink). Verify the activation
    # script exists and targets the mcp.json path.
    module-kiro-hm-writes-mcp-json = mkTest "kiro-hm-writes-mcp-json" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
        target = hmMcpDirTarget result;
      in
        lib.hasInfix "--phase all" (hmMcpWriteScript result)
        && target.path == ".kiro/settings"
        && target.units ? "mcp.json"
        && !(result.config.home.file ? ".kiro/settings/mcp.json")
    );

    # HM: lsp.json — verify LSP server config write.
    module-kiro-hm-writes-lsp-json = mkTest "kiro-hm-writes-lsp-json" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            lspServers.nix = {
              command = "nixd";
              args = [];
            };
          };
        };
        lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "nixd" (lspFile.text or "")
    );

    # HM: explicit `permissions` rules render permissions.yaml (source is a
    # pkgs.formats.yaml derivation, so we assert the file ENTRY exists).
    module-kiro-hm-permissions-explicit-rendered = mkTest "kiro-hm-permissions-explicit-rendered" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            permissions = [
              {
                capability = "mcp";
                effect = "allow";
                match = ["openmemory/*"];
              }
            ];
          };
        };
      in
        (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
    );

    # HM: under v3 (tui implies v3), `trustedMcpTools` is translated into
    # permissions.yaml — so the file is written even with no explicit rules.
    module-kiro-hm-permissions-translated-under-v3 = mkTest "kiro-hm-permissions-translated-under-v3" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            trustedMcpTools = ["@openmemory" "@git-mcp/git_diff" "subagent" "use_aws"];
          };
        };
      in
        (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
    );

    # HM: without v3 (no tui, no v3) and no explicit permissions, the
    # trustedMcpTools list is NOT translated — no permissions.yaml written.
    module-kiro-hm-permissions-absent-without-v3 = mkTest "kiro-hm-permissions-absent-without-v3" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            trustedMcpTools = ["@openmemory"];
          };
        };
      in
        !(result.config.home.file ? ".kiro/settings/permissions.yaml")
    );

    # HM: keyed rule steering entries with Kiro transformer frontmatter.
    # Verifies the kiro transformer emits `inclusion:` and `name:` fields.
    module-kiro-hm-writes-steering-files = mkTest "kiro-hm-writes-steering-files" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rules.my-steering = {
              matcher = ["src/**" "tests/**"];
              text = "Use strict mode always.";
            };
          };
        };
        steeringFile = (kiroSteeringFiles result)."my-steering.md" or null;
      in
        steeringFile
        != null
        && lib.hasInfix "Use strict mode always" (steeringFile.text or "")
        && lib.hasInfix "inclusion: fileMatch" (steeringFile.text or "")
        && lib.hasInfix "name: my-steering" (steeringFile.text or "")
        # CRITICAL: fileMatchPattern MUST be a YAML array for multi-element
        # paths, not a comma-joined string.
        && lib.hasInfix "fileMatchPattern: [" (steeringFile.text or "")
    );

    # Explicit Kiro inclusion modes are carried by runtime-native rules, so the
    # same config must render byte-identically in HM and devenv. Matchers remain
    # available to portable rules but do not leak a
    # fileMatchPattern into Kiro when an explicit non-fileMatch mode wins.
    module-kiro-inclusion-modes-hm-devenv-parity = mkTest "kiro-inclusion-modes-hm-devenv-parity" (
      let
        config = {
          ai = {
            kiro = {
              enable = true;
              rules.on-demand = {
                inclusion = "manual";
                matcher = ["docs/**"];
                text = "Load only when requested.";
              };
              rules.semantic = {
                description = "Semantic project guidance";
                inclusion = "auto";
                matcher = ["src/**"];
                text = "Load when the description matches.";
              };
            };
          };
        };
        hmSteering = kiroSteeringFiles (evalHm config);
        devenvSteering = kiroSteeringFiles (evalDevenv config);
        manual = (hmSteering."on-demand.md" or {}).text or "";
        auto = (hmSteering."semantic.md" or {}).text or "";
      in
        hmSteering."on-demand.md".text
        == devenvSteering."on-demand.md".text
        && hmSteering."semantic.md".text == devenvSteering."semantic.md".text
        && lib.hasInfix "inclusion: manual" manual
        && lib.hasInfix "inclusion: auto" auto
        && lib.hasInfix "description: Semantic project guidance" auto
        && !(lib.hasInfix "fileMatchPattern:" manual)
        && !(lib.hasInfix "fileMatchPattern:" auto)
    );

    module-kiro-inclusion-is-runtime-native = mkTest "kiro-inclusion-is-runtime-native" (
      let
        portableAttempt = builtins.tryEval (let
          result = evalHm {
            ai.rules.semantic = {
              description = "Semantic project guidance";
              inclusion = "auto";
              text = "Scoped guidance.";
            };
          };
        in
          builtins.deepSeq result.config.ai.rules.semantic true);
        native = evalHm {
          ai.kiro = {
            enable = true;
            rules.semantic = {
              description = "Semantic project guidance";
              inclusion = "auto";
              text = "Scoped guidance.";
            };
          };
        };
        kiro = ((kiroSteeringFiles native)."semantic.md" or {}).text or "";
      in
        !portableAttempt.success
        && lib.hasInfix "inclusion: auto" kiro
        && !(lib.hasInfix "fileMatchPattern:" kiro)
    );

    module-kiro-inclusion-invalid-enum-rejected = mkTest "kiro-inclusion-invalid-enum-rejected" (
      let
        ruleAttempt = builtins.tryEval (let
          result = evalDevenv {
            ai.kiro.rules.invalid = {
              inclusion = "sometimes";
              text = "Invalid";
            };
          };
        in
          builtins.deepSeq result.config.ai.kiro.rules.invalid true);
      in
        !ruleAttempt.success
    );

    # HM: per-CLI context → the `<contextFilename>` steering entry
    # (default AGENTS.md), delivered by the ordinary runtime file sink.
    module-kiro-hm-writes-context = mkTest "kiro-hm-writes-context" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            context.text = "Project conventions go here.";
          };
        };
        contextFile = (kiroSteeringFiles result)."AGENTS.md" or null;
      in
        contextFile
        != null
        && lib.hasInfix "Project conventions" (contextFile.text or "")
        && (result.config.home.file.".kiro/steering/AGENTS.md" or {}).text == contextFile.text
    );

    # HM: top-level ai.context fans out to kiro when per-CLI unset.
    module-kiro-hm-top-level-context-fallback = mkTest "kiro-hm-top-level-context-fallback" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.context.text = "Top-level context flows everywhere.";
        };
        contextFile = (kiroSteeringFiles result)."AGENTS.md" or null;
      in
        contextFile
        != null
        && lib.hasInfix "Top-level context" (contextFile.text or "")
    );

    # HM: per-runtime context appends after root context.
    module-kiro-hm-context-composes-root-first = mkTest "kiro-hm-context-composes-root-first" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            context.text = "Per-CLI context.";
          };
          ai.context.text = "Top-level context.";
        };
        contextFile = (kiroSteeringFiles result)."AGENTS.md" or null;
      in
        contextFile
        != null
        && contextFile.text == "Top-level context.\n\nPer-CLI context."
    );

    # HM: contextFilename override redirects the context emission.
    module-kiro-hm-context-filename-override = mkTest "kiro-hm-context-filename-override" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            context = {
              filename = "custom.md";
              text = "Custom filename.";
            };
          };
        };
        customFile = (kiroSteeringFiles result)."custom.md" or null;
        agentsFile = (kiroSteeringFiles result)."AGENTS.md" or null;
      in
        customFile != null && agentsFile == null
    );

    # HM: skills fanout via mkSkillEntries.
    module-kiro-hm-writes-skills = mkTest "kiro-hm-writes-skills" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.skills.stack-fix = ../../stacked-workflows/skills/stack-fix;
        };
        skillEntry = result.config.home.file.".kiro/skills/stack-fix" or null;
      in
        skillEntry != null
    );

    # HM: setting env vars PRODUCES a wrapper. Renamed from
    # `...-wrapper-exports-env-vars` — it never observed an export, only that the
    # installed package was the wrapped derivation. The export itself is asserted
    # behaviorally in packages/kiro-cli/checks/kiro-wrapper-argv.nix, which runs the wrapper and
    # reads `KIRO_WRAPPER_TEST` back out of the process.
    module-kiro-hm-env-vars-produce-wrapper = mkTest "kiro-hm-env-vars-produce-wrapper" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            environmentVariables.KIRO_LOG_LEVEL = "debug";
          };
        };
        packages = result.config.home.packages;
        first = builtins.head packages;
      in
        builtins.length packages
        == 1
        && first.name == "kiro-cli-wrapped"
    );

    # HM: extraPackages creates a wrapper carrying the store-backed PATH prefix.
    module-kiro-hm-extra-packages-reach-wrapper = let
      result = evalHm {
        ai.kiro = {
          enable = true;
          extraPackages = [pkgs.which];
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-hm-extra-packages-reach-wrapper";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["PATH" "${pkgs.which}/bin"];
      };

    # Devenv uses the same option and wrapper path as Home Manager.
    module-kiro-devenv-extra-packages-reach-wrapper = let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          extraPackages = [pkgs.which];
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-extra-packages-reach-wrapper";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["PATH" "${pkgs.which}/bin"];
      };

    # HM: no wrapper when nothing to wrap.
    module-kiro-hm-no-wrapper-when-nothing-to-wrap = mkTest "kiro-hm-no-wrapper-when-nothing-to-wrap" (
      let
        result = evalHm {
          ai.kiro.enable = true;
        };
        packages = result.config.home.packages;
        first = builtins.head packages;
      in
        builtins.length packages
        == 1
        && first.drvPath == result.config.ai.kiro.package.drvPath
        && first.name != "kiro-cli-wrapped"
    );

    # HM: agent JSON files written under configDir/agents/.
    module-kiro-hm-writes-agent-files = mkTest "kiro-hm-writes-agent-files" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            agents.reviewer = ''{"role": "reviewer"}'';
          };
        };
        agentFile = result.config.home.file.".kiro/agents/reviewer.json" or null;
      in
        agentFile != null
    );

    # A TYPED agent record lowers to JSON with `name` defaulted from the attr
    # key. That default is the whole point of the typed surface: Kiro's Rust CLI
    # REJECTS an agent file with no `name`, while the Node/ACP parser treats it
    # as optional — so an omission is invisible from the IDE and fatal on the
    # CLI. Also asserts null/empty fields are dropped, keeping the emitted file
    # to the minimal shape both parsers accept.
    module-kiro-typed-agent-defaults-name = mkTest "kiro-typed-agent-defaults-name" (
      let
        emitted = backend:
          builtins.fromJSON (backend {
            ai.kiro = {
              enable = true;
              agents.reviewer = {
                description = "Reviews diffs";
                prompt.text = "You review diffs.";
                tools = ["read" "shell"];
              };
            };
          });
        hmJson = emitted (cfg: (evalHm cfg).config.home.file.".kiro/agents/reviewer.json".text);
        devenvJson = emitted (cfg: (evalDevenv cfg).config.files.".kiro/agents/reviewer.json".text);
        wellFormed = j:
          j.name
          == "reviewer"
          && j.description == "Reviews diffs"
          && j.prompt == "You review diffs."
          && j.tools == ["read" "shell"]
          # null/empty optionals must not reach the file
          && !(j ? model)
          && !(j ? dispatchKind)
          && !(j ? resources)
          && !(j ? permissions);
      in
        wellFormed hmJson && wellFormed devenvJson && hmJson == devenvJson
    );

    # Pruning must reach INSIDE list elements. A permission rule declared without
    # `match`/`exclude` still carries their `[]` defaults, and a knowledge-base
    # resource its `include`/`exclude`. A pruner that only walks attrsets returns
    # the list untouched, so those empties reach the emitted file.
    module-kiro-typed-agent-prunes-in-lists = mkTest "kiro-typed-agent-prunes-in-lists" (
      let
        emitted =
          builtins.fromJSON
          (evalHm {
            ai.kiro = {
              enable = true;
              agents.scoped = {
                description = "d";
                permissions.rules = [
                  {
                    capability = "shell";
                    effect = "deny";
                  }
                ];
                prompt = {
                  enable = false;
                  text = "This disabled prompt must not be emitted.";
                };
                resources = [
                  {
                    type = "knowledgeBase";
                    source = "file:///docs";
                  }
                ];
              };
            };
          })
        .config
        .home
        .file
        .".kiro/agents/scoped.json"
        .text;
        rule = builtins.head emitted.permissions.rules;
        resource = builtins.head emitted.resources;
      in
        rule.capability
        == "shell"
        && rule.effect == "deny"
        && !(emitted ? prompt)
        && !(emitted ? welcomeMessage)
        && !(rule ? match)
        && !(rule ? exclude)
        && resource.source == "file:///docs"
        && !(resource ? include)
        && !(resource ? exclude)
        && !(resource ? name)
    );

    # Enabled optional text must carry content. Force the typed agent record so
    # the shared scalar text-source validation runs during module evaluation.
    module-kiro-typed-agent-enabled-empty-welcome-message-rejected = mkTest "kiro-typed-agent-enabled-empty-welcome-message-rejected" (
      let
        attempt = builtins.tryEval (let
          result = evalHm {
            ai.kiro = {
              enable = true;
              agents.empty-welcome.welcomeMessage.enable = true;
            };
          };
        in
          builtins.deepSeq result.config.ai.kiro.agents.empty-welcome.welcomeMessage true);
      in
        !attempt.success
    );

    # An explicit `name` overrides the attr-key default — Kiro keys the agent on
    # `name`, not on the filename, so this has to be reachable.
    module-kiro-typed-agent-explicit-name = mkTest "kiro-typed-agent-explicit-name" (
      let
        cfg =
          (evalHm {
            ai.kiro = {
              enable = true;
              agents.file-stem = {
                name = "explicit-id";
                description = "d";
              };
            };
          }).config;
      in
        (builtins.fromJSON cfg.home.file.".kiro/agents/file-stem.json".text).name
        == "explicit-id"
    );

    # Back-compat: a PATH-valued agent entry. Both backends must write the file
    # CONTENTS. devenv previously assigned the value straight to `files.*.text`,
    # which would have embedded the store path string as the file body (or
    # failed its `types.str` check) — the option type has always permitted a
    # path, and no test covered it, which is why the asymmetry survived.
    module-kiro-path-agent-both-backends = mkTest "kiro-path-agent-both-backends" (
      let
        mod = {
          ai.kiro = {
            enable = true;
            agents.from-file = ./fixtures/kiro-agent-raw.json;
          };
        };
        hmEntry = (evalHm mod).config.home.file.".kiro/agents/from-file.json";
        devenvEntry = (evalDevenv mod).config.files.".kiro/agents/from-file.json";
        # A path routes to `source` in BOTH backends, so neither stringifies it.
        resolves = e: (e.source or null) == ./fixtures/kiro-agent-raw.json;
      in
        resolves hmEntry && resolves devenvEntry
    );

    # `agents` and `agentsDir` are mutually exclusive; the assertion existed but
    # nothing exercised it.
    module-kiro-agents-dir-exclusive = mkTest "kiro-agents-dir-exclusive" (
      let
        cfg =
          (evalHm {
            ai.kiro = {
              enable = true;
              agents.reviewer = ''{"name":"reviewer"}'';
              agentsDir = ./fixtures/kiro-agents-dir;
            };
          }).config;
        failed = builtins.filter (a: !a.assertion) cfg.assertions;
      in
        builtins.length failed
        == 1
        && lib.hasInfix "cannot set both" (builtins.head failed).message
    );

    # `agentsDir` alone symlinks the directory wholesale (HM Layout B).
    module-kiro-agents-dir-symlinks = mkTest "kiro-agents-dir-symlinks" (
      let
        entry =
          (evalHm {
            ai.kiro = {
              enable = true;
              agentsDir = ./fixtures/kiro-agents-dir;
            };
          }).config.home.file.".kiro/agents";
      in
        entry.source == ./fixtures/kiro-agents-dir && entry.recursive
    );

    # HM: hook JSON files written under configDir/hooks/.
    module-kiro-hm-writes-hook-files = mkTest "kiro-hm-writes-hook-files" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            hooksJson.pre-commit = ''{"event": "pre-commit"}'';
          };
        };
        hookUnits = (hmHookTarget result).units;
      in
        # The unit ADDRESS is exact now, not a substring of a script: a body
        # that happens to mention a name proves nothing about what it wrote.
        builtins.attrNames hookUnits
        == ["pre-commit.json"]
        && lib.hasInfix ''"event": "pre-commit"'' hookUnits."pre-commit.json".text
    );

    # HM: a TYPED hook record lowers to the correct v3 envelope JSON. name = attr
    # key; null optionals dropped; action nulls dropped.
    module-kiro-hooks-typed-hm-emits-envelope = mkTest "kiro-hooks-typed-hm-emits-envelope" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            hooks.lint = {
              trigger = "PostToolUse";
              matcher = "fs_write";
              action.command = "just lint";
              timeout = 30;
            };
          };
        };
        t = (hmHookTarget result).units."lint.json".text;
      in
        lib.hasInfix ''"version":"v1"'' t
        && lib.hasInfix ''"name":"lint"'' t
        && lib.hasInfix ''"trigger":"PostToolUse"'' t
        && lib.hasInfix ''"matcher":"fs_write"'' t
        && lib.hasInfix ''"type":"command"'' t
        && lib.hasInfix ''"command":"just lint"'' t
        && lib.hasInfix ''"timeout":30'' t
        # `enabled`/`description` were null → omitted.
        && !(lib.hasInfix ''"enabled"'' t)
        && !(lib.hasInfix ''"description"'' t)
    );

    # HM: S1 — an `action.command` package coerces to its getExe store path so
    # companion files ride the closure at an absolute, cwd-independent path.
    module-kiro-hooks-command-accepts-package = mkTest "kiro-hooks-command-accepts-package" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            hooks.fmt = {
              trigger = "PostToolUse";
              action.command = pkgs.hello;
            };
          };
        };
        t = (hmHookTarget result).units."fmt.json".text;
      in
        lib.hasInfix ''"command":"/nix/store'' t && lib.hasInfix "/bin/hello" t
    );

    # HM↔devenv: the same typed hook lands as a REAL file on both backends
    # (v3 skips symlinked hooks), through the shared materializer.
    module-kiro-hooks-typed-devenv-installs = mkTest "kiro-hooks-typed-devenv-installs" (
      let
        cfg = {
          ai.kiro = {
            enable = true;
            hooks.lint = {
              trigger = "PostToolUse";
              action.command = "just lint";
            };
          };
        };
        dv = evalDevenv cfg;
        hmTarget = hmHookTarget (evalHm cfg);
        dvTarget = dvHookTarget dv;
      in
        lib.hasInfix ''"trigger":"PostToolUse"'' hmTarget.units."lint.json".text
        # Parity is an EQUALITY of the two plans' units now, rather than one
        # substring appearing in two different scripts.
        && dvTarget.units == hmTarget.units
        && dvTarget.path == ".kiro/hooks"
        # The write is anchored to the project root without a `cd`: devenv runs
        # a task in the caller's cwd (direnv activates in subdirectories), and
        # `own` resolves every path against the exported root instead.
        && lib.hasInfix ''NAT_OWN_ROOT="$DEVENV_ROOT"'' (dvHookTaskExec dv)
        # NOT a devenv `files.*` symlink
        && !(dv.config.files ? ".kiro/hooks/lint.json")
        # the enterTest backstop still asserts it landed as a real file, and
        # against the SAME plan the task applies (own.py --verify checks every
        # declared dir unit). Every own bundle contributes a verify, so the
        # assertion is that THIS plan is among them.
        && lib.hasInfix "--verify" (dv.config.enterTest or "")
        && hasLiteral (ownPlanArg (dvHookTaskExec dv)) (dv.config.enterTest or "")
    );

    # HM+devenv: records sharing a `file` co-locate into ONE envelope (N hooks in
    # one file — the typed path off the raw `hooksJson` escape hatch, e.g.
    # several hooks sharing one kiro-memory.json). A record without `file` keeps its own
    # <name>.json (back-compat); the Nix-only `file` key is stripped from output.
    # PR #433 moved HM hook delivery to home.activation real files (kiro v3 skips
    # store symlinks), so each envelope is asserted structurally via fromJSON —
    # same strength as the old home.file text read. The writer is `own` now, so
    # each envelope is a UNIT in the plan; the heredoc extraction that used to
    # recover it from a content-hash-derived EOF marker is gone.
    module-kiro-hooks-typed-colocation = mkTest "kiro-hooks-typed-colocation" (
      let
        cfg = {
          ai.kiro = {
            enable = true;
            hooks = {
              mem-stop = {
                file = "kiro-memory";
                trigger = "Stop";
                action.command = "/bin/stop";
              };
              mem-recall = {
                file = "kiro-memory";
                trigger = "UserPromptSubmit";
                action.command = "/bin/recall";
              };
              solo = {
                trigger = "PostToolUse";
                matcher = "fs_write";
                action.command = "/bin/solo";
              };
            };
          };
        };
        hookUnits = (hmHookTarget (evalHm cfg)).units;
        # A hook command may be a package, so a unit's text can carry store
        # context, and every substring inherits the whole string's — which
        # fromJSON rejects. Strip it; byte content is unchanged.
        hookBody = file: builtins.unsafeDiscardStringContext hookUnits."${file}.json".text;
        coText = hookBody "kiro-memory";
        co = builtins.fromJSON coText;
        soloText = hookBody "solo";
        dvUnits = (dvHookTarget (evalDevenv cfg)).units;
      in
        # both co-located records land in ONE kiro-memory.json envelope
        co.version
        == "v1"
        && builtins.length co.hooks == 2
        && lib.any (h: h.name == "mem-stop" && h.trigger == "Stop") co.hooks
        && lib.any (h: h.name == "mem-recall" && h.trigger == "UserPromptSubmit") co.hooks
        # the Nix-only `file` grouping key is stripped from every emitted hook object
        && !(lib.any (h: h ? file) co.hooks)
        && !(lib.hasInfix ''"file"'' coText)
        # a record without `file` keeps its own <name>.json (back-compat)
        && lib.hasInfix ''"name":"solo"'' soloText
        # the co-located records do NOT also emit their own per-record files
        && builtins.attrNames hookUnits == ["kiro-memory.json" "solo.json"]
        # devenv installs the SAME grouped file (parity) and NOT per-record files
        && dvUnits == hookUnits
    );

    # A PATH-valued hooksJson entry must emit the file CONTENT, not the path string
    # (mkAllHookFiles resolves paths so devenv's writeText writes the body too).
    module-kiro-hooks-json-path-resolves = mkTest "kiro-hooks-json-path-resolves" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            hooksJson.raw = ./fixtures/kiro-hook-raw.json;
          };
        };
        t = (hmHookTarget result).units."raw.json".text;
      in
        lib.hasInfix "raw-envelope-loaded" t
    );

    # Hardening (PR #433 review): an unsafe hook name (path separator) fails the
    # name-charset assertion before it can be interpolated into a hooks-dir path.
    module-kiro-hooks-rejects-unsafe-name = mkTest "kiro-hooks-rejects-unsafe-name" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            hooksJson."../evil" = builtins.toJSON {
              version = "v1";
              hooks = [];
            };
          };
        };
        nameAsserts =
          builtins.filter (a: lib.hasInfix "hook names must match" a.message)
          ev.config.assertions;
      in
        nameAsserts != [] && (builtins.head nameAsserts).assertion == false
    );

    # A safe hook name passes the same assertion (assertion == true).
    module-kiro-hooks-accepts-safe-name = mkTest "kiro-hooks-accepts-safe-name" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            hooksJson."kiro-memory.pre_1" = builtins.toJSON {
              version = "v1";
              hooks = [];
            };
          };
        };
        nameAsserts =
          builtins.filter (a: lib.hasInfix "hook names must match" a.message)
          ev.config.assertions;
      in
        nameAsserts != [] && (builtins.head nameAsserts).assertion == true
    );

    # Hardening (PR #433 review): the HM hook writer prunes first, so a hook
    # removed or renamed in config stops firing. The prune is a LEDGER walk,
    # not a whole-dir `*.json` glob — see the ownership test below for why that
    # distinction is load-bearing.
    #
    # The prune and the write are two phases of ONE plan, which is the property
    # that replaces the old "the prune's keep-case must carry the current name"
    # assertion: a single plan cannot disagree with itself about what is
    # declared, so a name in it is kept by construction. `ai-own-runtime`
    # proves the phase semantics; this proves kiro wired one plan to both.
    module-kiro-hooks-hm-prunes-stale = mkTest "kiro-hooks-hm-prunes-stale" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            hooksJson.demo = builtins.toJSON {
              version = "v1";
              hooks = [];
            };
          };
        };
        prune = hmHookPruneScript ev;
        write = hmHookWriteScript ev;
      in
        lib.hasInfix "--phase prune" prune
        && lib.hasInfix "--phase all" write
        && lib.hasInfix "set -euETo pipefail" prune
        && ownPlanArg prune == ownPlanArg write
        && (hmHookTarget ev).units ? "demo.json"
    );

    # THE DEFECT (N→0). The hook writers must exist whenever the module is
    # enabled — NOT gated on a non-empty hook set — so REMOVING THE LAST HOOK
    # still prunes. The previous writers carried their prune inside
    # `mkIf (hooks != {} || hooksJson != {})` / `mkIf (hooksDir != null)`, so
    # emptying the surface emitted nothing at all, the prune never ran, and
    # every previously written hook file stayed on disk and kept firing —
    # forever, since nothing else claims that directory. Both backends.
    module-kiro-hooks-empty-set-still-prunes = mkTest "kiro-hooks-empty-set-still-prunes" (
      let
        hm = evalHm {ai.kiro.enable = true;};
        prune = hmHookPruneScript hm;
        write = hmHookWriteScript hm;
        dv = evalDevenv {ai.kiro.enable = true;};
        hmTarget = hmHookTarget hm;
      in
        # no hooks declared at all…
        hm.config.ai.kiro.hooks
        == {}
        && hm.config.ai.kiro.hooksJson == {}
        && hm.config.ai.kiro.hooksDir == null
        # …yet BOTH phases are still emitted, against a plan that still names
        # the hooks directory and the ledger the previous generation wrote. An
        # empty declaration is the retirement: own.py removes every unit that
        # ledger records and then unlinks it.
        && lib.hasInfix "--phase prune" prune
        && lib.hasInfix "--phase all" write
        && hmTarget.units == {}
        && hmTarget.path == ".kiro/hooks"
        && hmTarget.ledger == "materialize/kiro-hooks.manifest"
        # …and devenv keeps its task, for the same reason
        && lib.hasInfix "--phase all" (dvHookTaskExec dv)
        && (dvHookTarget dv).units == {}
    );

    # THE TRAP the fix had to avoid. Making the OLD prune unconditional would
    # have made `rm -f "$HOOKS_DIR"/*.json` run on every activation for every
    # consumer who merely enables `ai.kiro` — deleting hand-placed hooks this
    # module never wrote. Deletion must be reachable only through the ledger.
    #
    # This used to assert the literal `.nat-tmp.` infix in the generated shell,
    # as a proxy for "the one non-ledger deletion class is the reserved
    # stale-temp sweep". There is no generated shell to grep now: every body is
    # one command whose arguments are two store paths and a phase, so the
    # property is asserted where it lives — no body names a hook, a glob or a
    # removal, and the deletion set comes from the plan's ledger.
    # `ai-own-runtime` proves the sweep is the only non-ledger deletion, and
    # `module-kiro-hooks-materialize-runtime` below proves an unmanaged file
    # survives three generations.
    module-kiro-hooks-prune-is-ledger-scoped = mkTest "kiro-hooks-prune-is-ledger-scoped" (
      let
        cfg = {
          ai.kiro = {
            enable = true;
            hooksJson.demo = builtins.toJSON {
              version = "v1";
              hooks = [];
            };
          };
        };
        hm = evalHm cfg;
        dv = evalDevenv cfg;
        scripts = [
          (hmHookPruneScript hm)
          (hmHookWriteScript hm)
          (dvHookTaskExec dv)
        ];
        forbidden = ["*.json" "demo.json" "rm " "unlink" ".kiro/hooks"];
      in
        builtins.all (script: builtins.all (needle: !(hasLiteral needle script)) forbidden) scripts
        # …and the ledger every phase reads is the declared one, from the plan
        && (hmHookTarget hm).ledger == "materialize/kiro-hooks.manifest"
        && (dvHookTarget dv).ledger == "materialize/kiro-hooks.manifest"
    );

    # The hooks task and legacy steering-retirement task share one materializer
    # state directory and devenv may run them concurrently. The lock is
    # deliberately STATE-DIR-wide, not per slug: every stale-temp sweep must
    # exclude every other writer's live manifest temp before it can delete the
    # reserved `.nat-tmp.` namespace. Prove both generated tasks block behind
    # that lock, then release it and run them concurrently. Hooks still
    # materialize; steering must not, because the native files layer owns it.
    module-kiro-materializer-tasks-serialize-runtime = let
      ev = evalDevenv {
        ai.kiro = {
          enable = true;
          hooksJson.demo = builtins.toJSON {
            version = "v1";
            hooks = [];
          };
          rules.serialized = {
            matcher = ["**"];
            text = "SERIALIZED-STEERING-TOKEN.";
          };
        };
      };
      hookTask = pkgs.writeShellScript "kiro-hooks-lock-probe" (dvHookTaskExec ev);
      steeringTask = pkgs.writeShellScript "kiro-steering-lock-probe" (dvTaskExec ev);
    in
      pkgs.runCommand "module-test-kiro-materializer-tasks-serialize-runtime" {
        inherit hookTask steeringTask;
      } ''
        set -u
        fail() { echo "FAIL: kiro-materializer-tasks-serialize-runtime: $1" >&2; exit 1; }

        export DEVENV_ROOT="$TMPDIR/root"
        export DEVENV_STATE="$TMPDIR/state"
        state_dir="$DEVENV_STATE/nix-agentic-tools/materialize"
        steering_dir="$DEVENV_ROOT/.kiro/steering"
        ${pkgs.coreutils}/bin/mkdir -p "$steering_dir" "$state_dir"
        printf 'legacy steering\n' > "$steering_dir/legacy.md"
        legacy_hash="$(${pkgs.coreutils}/bin/sha256sum "$steering_dir/legacy.md" | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
        printf 'legacy.md\t%s\n' "$legacy_hash" > "$state_dir/kiro-steering.manifest"

        exec 9> "$state_dir/lock"
        ${lib.getExe pkgs.flock} 9
        for probe in hookTask steeringTask; do
          task="''${!probe}"
          if ${pkgs.coreutils}/bin/timeout 1 "$task"; then
            fail "$probe ignored the shared materializer lock"
          else
            timeout_code=$?
          fi
          [ "$timeout_code" -eq 124 ] \
            || fail "$probe failed with $timeout_code instead of blocking on the lock"
        done
        ${lib.getExe pkgs.flock} -u 9
        exec 9>&-

        "$hookTask" &
        hook_pid=$!
        "$steeringTask" &
        steering_pid=$!
        wait "$hook_pid"
        wait "$steering_pid"

        [ -f "$DEVENV_ROOT/.kiro/hooks/demo.json" ] \
          || fail "hook task did not materialize demo.json"
        [ ! -e "$DEVENV_ROOT/.kiro/steering/serialized.md" ] \
          || fail "legacy retirement task materialized native steering"
        [ ! -e "$steering_dir/legacy.md" ] \
          || fail "legacy retirement task did not prune owned steering"
        [ ! -e "$state_dir/kiro-steering.manifest" ] \
          || fail "legacy retirement task did not remove its manifest"
        manifests=("$state_dir"/*.manifest)
        [ "''${#manifests[@]}" -eq 1 ] \
          || fail "concurrent hook task did not preserve its manifest"

        echo "PASS: kiro-materializer-tasks-serialize-runtime" > $out
      '';

    # RUNTIME proof of the two properties the string assertions above can only
    # approximate. Grepping generated bash cannot show that a file is actually
    # deleted or actually left alone, and both are the whole point of this
    # surface — so RUN the real writers across three generations, on BOTH
    # backends, against a sandbox HOME/DEVENV_ROOT:
    #
    #   gen 1: two hooks           → both materialize as real 0444 files
    #   gen 2: one hook            → the dropped hook is pruned
    #   gen 3: NO hooks at all     → the last hook is pruned (N→0, the defect)
    #
    # A hand-placed `handwritten.json` is planted after gen 1 and must survive
    # all of it (the ownership decision: this claims only what it wrote).
    #
    # `mkTest`'s eval-time assertion cannot express this, so it is a plain
    # runCommand. No strict-mode header: stdenv's setup.sh already sets all
    # four and phases share one shell (see the Bash standard's per-site table).
    module-kiro-hooks-materialize-runtime = let
      mkHook = command:
        builtins.toJSON {
          version = "v1";
          hooks = [
            {
              name = "probe";
              trigger = "Stop";
              action = {
                type = "command";
                inherit command;
              };
            }
          ];
        };
      genCfg = hooks: {
        ai.kiro = {
          enable = true;
          hooksJson = hooks;
        };
      };
      gens = [
        (genCfg {
          alpha = mkHook "alpha";
          beta = mkHook "beta";
        })
        (genCfg {alpha = mkHook "alpha";})
        (genCfg {})
      ];
      # HM delivers as a PAIR (prune entryBefore checkLinkTargets, write
      # entryAfter linkGeneration); replay them in that order.
      hmGen = cfg: let
        ev = evalHm cfg;
      in
        pkgs.writeShellScript "kiro-hooks-hm-gen"
        (hmHookPruneScript ev + "\n" + hmHookWriteScript ev);
      dvGen = cfg: pkgs.writeShellScript "kiro-hooks-dv-gen" (dvHookTaskExec (evalDevenv cfg));
    in
      pkgs.runCommand "module-test-kiro-hooks-materialize-runtime" {
        hmGens = map hmGen gens;
        dvGens = map dvGen gens;
      } ''
        set -u
        fail() { echo "FAIL: kiro-hooks-materialize-runtime: $1" >&2; exit 1; }

        run_backend() {
          backend="$1"
          hooks_dir="$2"
          shift 2

          gen1="$1"; gen2="$2"; gen3="$3"

          "$gen1"
          [ -f "$hooks_dir/alpha.json" ] || fail "$backend gen1: alpha.json missing"
          [ -f "$hooks_dir/beta.json" ] || fail "$backend gen1: beta.json missing"
          [ ! -L "$hooks_dir/alpha.json" ] || fail "$backend gen1: alpha.json is a symlink (v3 would skip it)"
          [ "$(${pkgs.coreutils}/bin/stat -c %a "$hooks_dir/alpha.json")" = 444 ] \
            || fail "$backend gen1: alpha.json is not the managed read-only mode"
          ${pkgs.gnugrep}/bin/grep -q '"command":"alpha"' "$hooks_dir/alpha.json" \
            || fail "$backend gen1: alpha.json content not materialized"

          # A hook this module never wrote. It must survive every later
          # generation — the old whole-dir `rm -f "$HOOKS_DIR"/*.json` ate it.
          echo '{"handwritten":true}' > "$hooks_dir/handwritten.json"

          "$gen2"
          [ -f "$hooks_dir/alpha.json" ] || fail "$backend gen2: alpha.json vanished"
          [ ! -e "$hooks_dir/beta.json" ] || fail "$backend gen2: removed hook beta.json still on disk"
          [ -f "$hooks_dir/handwritten.json" ] || fail "$backend gen2: unmanaged hook was deleted"

          # THE DEFECT: emptying the surface must still prune. Under the old
          # `mkIf`-gated writer this generation emitted nothing at all and
          # alpha.json kept firing forever.
          "$gen3"
          [ ! -e "$hooks_dir/alpha.json" ] || fail "$backend gen3: N->0 did not prune alpha.json"
          [ -f "$hooks_dir/handwritten.json" ] || fail "$backend gen3: unmanaged hook was deleted"
          ${pkgs.gnugrep}/bin/grep -q handwritten "$hooks_dir/handwritten.json" \
            || fail "$backend gen3: unmanaged hook was rewritten"
        }

        export HOME="$TMPDIR/hm-home"
        export XDG_STATE_HOME="$HOME/.local/state"
        ${pkgs.coreutils}/bin/mkdir -p "$HOME"
        run_backend hm "$HOME/.kiro/hooks" $hmGens

        export DEVENV_ROOT="$TMPDIR/dv-root"
        export DEVENV_STATE="$TMPDIR/dv-state"
        ${pkgs.coreutils}/bin/mkdir -p "$DEVENV_ROOT" "$DEVENV_STATE"
        run_backend devenv "$DEVENV_ROOT/.kiro/hooks" $dvGens

        echo "PASS: kiro-hooks-materialize-runtime" > $out
      '';

    # Devenv: mcp.json write — real-file task delivery (no files.*
    # symlink), anchored to $DEVENV_ROOT.
    module-kiro-devenv-writes-mcp-json = mkTest "kiro-devenv-writes-mcp-json" (
      let
        result = evalDevenv {
          ai.kiro.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
        target = dvMcpDirTarget result;
      in
        target.path
        == ".kiro/settings"
        && target.units ? "mcp.json"
        && (dvMcpDocTarget result).path == ".kiro/settings/mcp.json"
        # anchored to the project root without a `cd` in the task body
        && lib.hasInfix ''NAT_OWN_ROOT="$DEVENV_ROOT"'' (dvMcpTaskExec result)
        && !(result.config.files ? ".kiro/settings/mcp.json")
    );

    # Devenv: lsp.json write.
    module-kiro-devenv-writes-lsp-json = mkTest "kiro-devenv-writes-lsp-json" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            lspServers.nix = {
              command = "nixd";
              args = [];
            };
          };
        };
        lspFile = result.config.files.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "nixd" (lspFile.text or "")
    );

    # Devenv: environment variables are baked into the launcher, not exported
    # into the project shell (which is what the old `env` blob did).
    module-kiro-devenv-env-wrapper-populated = let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          environmentVariables.KIRO_LOG_LEVEL = "debug";
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-env-wrapper-populated";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["KIRO_LOG_LEVEL" "debug"];
      };

    # Devenv: settings/cli.json static write.
    module-kiro-devenv-writes-settings-json = mkTest "kiro-devenv-writes-settings-json" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            # Workspace-overridable on purpose: `telemetry.enabled` used to stand
            # here, and the workspace-allowlist guard now (correctly) rejects it,
            # which would leave this exercising a config the module declares
            # invalid. The subject of the test — that settings reach the file at
            # all — is unchanged.
            nativeSettings.chat.enableTangentMode = true;
          };
        };
        settingsFile = result.config.files.".kiro/settings/cli.json" or null;
      in
        settingsFile
        != null
        && lib.hasInfix "chat.enableTangentMode" (settingsFile.text or "")
    );

    # Devenv: Kiro context joins the shared repository-root AGENTS.md.
    module-kiro-devenv-writes-context = mkTest "kiro-devenv-writes-context" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            context.text = "Project conventions go here.";
          };
        };
        contextFile = result.config.files."AGENTS.md" or null;
      in
        contextFile
        != null
        && lib.hasInfix "Project conventions" (contextFile.text or "")
        && !((kiroSteeringFiles result) ? "AGENTS.md")
    );

    # Devenv: top-level ai.context fans to kiro when per-CLI unset.
    module-kiro-devenv-top-level-context-fallback = mkTest "kiro-devenv-top-level-context-fallback" (
      let
        result = evalDevenv {
          ai.kiro.enable = true;
          ai.context.text = "Top-level context flows everywhere.";
        };
        contextFile = result.config.files."AGENTS.md" or null;
      in
        contextFile
        != null
        && lib.hasInfix "Top-level context" (contextFile.text or "")
    );

    # Devenv: agent files written.
    module-kiro-devenv-writes-agent-files = mkTest "kiro-devenv-writes-agent-files" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            agents.reviewer = ''{"role": "reviewer"}'';
          };
        };
        agentFile = result.config.files.".kiro/agents/reviewer.json" or null;
      in
        agentFile
        != null
        && lib.hasInfix "reviewer" (agentFile.text or "")
    );

    # Devenv: hook files written as REAL files by the materialize task (kiro v3
    # does not discover symlinked hooks, so devenv `files.*` symlinks are wrong
    # here — the task writes a plain `.kiro/hooks/<name>.json`).
    module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            hooksJson.pre-commit = ''{"event": "pre-commit"}'';
          };
        };
        target = dvHookTarget result;
      in
        builtins.attrNames target.units
        == ["pre-commit.json"]
        && lib.hasInfix ''{"event": "pre-commit"}'' target.units."pre-commit.json".text
        && target.path == ".kiro/hooks"
        # anchored to the project root without a `cd`: the task runs in the
        # caller's cwd (direnv activates in subdirectories) and every path is
        # resolved against the exported root
        && lib.hasInfix ''NAT_OWN_ROOT="$DEVENV_ROOT"'' (dvHookTaskExec result)
        # not a devenv `files.*` symlink
        && !(result.config.files ? ".kiro/hooks/pre-commit.json")
        # the write is ordered before shell entry, and after devenv's own
        # files cleanup (same edge contract as the steering task)
        && result.config.tasks."ai:kiro:materialize-hooks".after
        == ["devenv:files:cleanup"]
    );

    # Devenv: the external `hooksDir` surface materializes the directory's
    # top-level `*.json` files into `.kiro/hooks/` as real files — same
    # v3-symlink rationale as the inline surface above, same project-root
    # anchoring, and now the SAME manifest, so flipping between the two
    # surfaces prunes the previous one instead of orphaning it.
    #
    # Also pins what is deliberately dropped vs. the retired `cp -rL`: a
    # subdirectory and a non-`.json` sibling in the fixture are BOTH ignored.
    # Kiro loads neither, and the retired whole-dir prune never removed
    # either — but the `.json` filter is additionally what keeps a dotfile
    # like `.gitkeep` from tripping the copy-mode name regex.
    module-kiro-devenv-hooks-dir-materializes = mkTest "kiro-devenv-hooks-dir-materializes" (
      let
        cfg = {
          ai.kiro = {
            enable = true;
            hooksDir = ./fixtures/kiro-hooks-dir;
          };
        };
        result = evalDevenv cfg;
        target = dvHookTarget result;
        hmTarget = hmHookTarget (evalHm cfg);
      in
        # A directory entry travels as a STORE path, not as text read at eval,
        # so the content assertion reads the file the unit points at.
        builtins.attrNames target.units
        == ["sample.json"]
        && lib.hasInfix "hooks-dir-sample" (builtins.readFile target.units."sample.json".store)
        && target.path == ".kiro/hooks"
        # HM parity — same unit, same ledger, no second mechanism
        && hmTarget == target
        # anchored to the project root without a `cd`
        && lib.hasInfix ''NAT_OWN_ROOT="$DEVENV_ROOT"'' (dvHookTaskExec result)
        # dropped: the subdirectory and the non-`.json` sibling are ignored
        && !(target.units ? "nested")
        && !(target.units ? "inner.json")
        && !(target.units ? "ignore-me.txt")
        # real files, not devenv `files.*` symlinks
        && !(lib.any (n: lib.hasPrefix ".kiro/hooks/" n) (lib.attrNames result.config.files))
        # the enterTest backstop covers the dir surface too, against this plan
        && lib.hasInfix "--verify" (result.config.enterTest or "")
        && hasLiteral (ownPlanArg (dvHookTaskExec result)) (result.config.enterTest or "")
    );

    # `hooksDir` unset again (N→0 for the DIR surface specifically): the writers
    # survive, so the files the previous generation copied out of that directory
    # are pruned rather than left firing. The old `mkIf (hooksDir != null)` gate
    # made this the exact case that leaked.
    module-kiro-hooks-dir-unset-still-prunes = mkTest "kiro-hooks-dir-unset-still-prunes" (
      let
        hm = evalHm {ai.kiro.enable = true;};
        dv = evalDevenv {ai.kiro.enable = true;};
        withDir = evalHm {
          ai.kiro = {
            enable = true;
            hooksDir = ./fixtures/kiro-hooks-dir;
          };
        };
      in
        # the dir surface really does produce a managed unit…
        (hmHookTarget withDir).units
        ? "sample.json"
        # …and with it back to null the prune pass is still emitted, on both
        # backends, against the ledger that recorded `sample.json`
        && hm.config.ai.kiro.hooksDir == null
        && lib.hasInfix "--phase prune" (hmHookPruneScript hm)
        && (hmHookTarget hm).units == {}
        && (hmHookTarget hm).ledger == (hmHookTarget withDir).ledger
        && lib.hasInfix "--phase all" (dvHookTaskExec dv)
        && (dvHookTarget dv).units == {}
    );

    # A `hooksDir` filename outside the hook-name charset must fail at EVAL
    # with a NAMED assertion. `hookNameAssertion` covers only the inline
    # surfaces' attr keys; without this one the dir surface would reach `own`,
    # which refuses a dot-prefixed unit address with a throw that names no
    # option.
    module-kiro-hooks-dir-rejects-unsafe-filename = mkTest "kiro-hooks-dir-rejects-unsafe-filename" (
      let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            hooksDir = ./fixtures/kiro-hooks-dir-unsafe;
          };
        };
        nameAsserts =
          builtins.filter (a: lib.hasInfix "hook file names must match" a.message)
          ev.config.assertions;
      in
        nameAsserts != [] && (builtins.head nameAsserts).assertion == false
    );

    # ── Kiro steering through ai.kiro.files ─────────────────────────────

    # Two generators producing the same target with divergent whole entries at
    # the same priority must fail. A rule named "AGENTS" and the default context
    # filename deliberately collide here.
    module-kiro-steering-collision-errors = mkTest "kiro-steering-collision-errors" (
      let
        attempt = builtins.tryEval (
          let
            ev = evalHm {
              ai.kiro = {
                enable = true;
                context.text = "CONTEXT-COLLIDER.";
                rules.AGENTS.text = "RULE-COLLIDER.";
              };
            };
          in
            builtins.seq ev.config.ai.kiro.files.".kiro/steering/AGENTS.md".text true
        );
      in
        !attempt.success
    );

    # One-shot legacy retirement sits outside the runtime enable gate so an
    # upgrade+disable generation still drains old ownership manifests. It is a
    # manifest-absent no-op and writes no steering content.
    module-kiro-steering-legacy-copies-still-prune = mkTest "kiro-steering-legacy-copies-still-prune" (
      let
        hm = evalHm {ai.kiro.enable = false;};
        retirement = hmRetirementScript hm;
        dv = evalDevenv {ai.kiro.enable = false;};
        task = dv.config.tasks."ai:kiro:retire-steering-copies" or null;
      in
        hm.config.ai.kiro.files
        == {}
        && lib.hasInfix "NAT_MAT_RETIRE_MANIFEST" retirement
        && lib.hasInfix "rm -f -- \"$NAT_MAT_MANIFEST\"" retirement
        && !(lib.hasInfix "NAT_MAT_NEW_MANIFEST" retirement)
        && task != null
        && lib.hasInfix "NAT_MAT_RETIRE_MANIFEST" (task.exec or "")
        && lib.hasInfix "$NAT_MAT_MANIFEST" (task.exec or "")
    );

    module-kiro-steering-legacy-retirement-runtime = let
      hmScript = pkgs.writeShellScript "kiro-steering-hm-retirement" (
        hmRetirementScript (evalHm {ai.kiro.enable = false;})
      );
      devenvScript = pkgs.writeShellScript "kiro-steering-devenv-retirement" (
        dvTaskExec (evalDevenv {ai.kiro.enable = false;})
      );
    in
      pkgs.runCommand "module-test-kiro-steering-legacy-retirement-runtime" {
        inherit devenvScript hmScript;
      } ''
        fail() { echo "FAIL: kiro-steering-legacy-retirement-runtime: $1" >&2; exit 1; }

        hm_home="$TMPDIR/hm-home"
        hm_state="$TMPDIR/hm-state"
        hm_target="$hm_home/.kiro/steering"
        hm_ledger="$hm_state/nix-agentic-tools/materialize"
        mkdir -p "$hm_target" "$hm_ledger"
        printf 'managed hm\n' > "$hm_target/managed.md"
        printf 'unmanaged hm\n' > "$hm_target/unmanaged.md"
        hm_hash="$(sha256sum "$hm_target/managed.md" | cut -d ' ' -f 1)"
        printf 'managed.md\t%s\n' "$hm_hash" > "$hm_ledger/kiro-steering.manifest"
        HOME="$hm_home" XDG_STATE_HOME="$hm_state" "$hmScript"
        [ ! -e "$hm_target/managed.md" ] || fail "HM kept the owned legacy copy"
        [ -e "$hm_target/unmanaged.md" ] || fail "HM removed an unmanaged file"
        [ ! -e "$hm_ledger/kiro-steering.manifest" ] || fail "HM kept the retired manifest"

        dv_root="$TMPDIR/dv-root"
        dv_state="$TMPDIR/dv-state"
        dv_target="$dv_root/.kiro/steering"
        dv_ledger="$dv_state/nix-agentic-tools/materialize"
        mkdir -p "$dv_target" "$dv_ledger"
        printf 'managed devenv\n' > "$dv_target/managed.md"
        printf 'unmanaged devenv\n' > "$dv_target/unmanaged.md"
        dv_hash="$(sha256sum "$dv_target/managed.md" | cut -d ' ' -f 1)"
        printf 'managed.md\t%s\n' "$dv_hash" > "$dv_ledger/kiro-steering.manifest"
        DEVENV_ROOT="$dv_root" DEVENV_STATE="$dv_state" "$devenvScript"
        [ ! -e "$dv_target/managed.md" ] || fail "devenv kept the owned legacy copy"
        [ -e "$dv_target/unmanaged.md" ] || fail "devenv removed an unmanaged file"
        [ ! -e "$dv_ledger/kiro-steering.manifest" ] || fail "devenv kept the retired manifest"

        echo "PASS: kiro-steering-legacy-retirement-runtime" > "$out"
      '';

    # The pinned Kiro follows steering symlinks. Both backends therefore lower
    # conditional steering through their ordinary native file sink, while
    # unscoped devenv content still goes to the shared AGENTS.md owner.
    module-kiro-steering-uses-runtime-file-sinks = mkTest "kiro-steering-uses-runtime-file-sinks" (
      let
        config = {
          ai.kiro = {
            enable = true;
            context.text = "CONTEXT-TOKEN.";
            rules.enter-test = {
              matcher = ["src/**"];
              text = "ENTER-TEST-TOKEN.";
            };
          };
        };
        hm = evalHm config;
        dv = evalDevenv config;
      in
        hm.config.home.file.".kiro/steering/enter-test.md".text
        == hm.config.ai.kiro.files.".kiro/steering/enter-test.md".text
        && hm.config.home.file.".kiro/steering/AGENTS.md".text
        == hm.config.ai.kiro.files.".kiro/steering/AGENTS.md".text
        && dv.config.files.".kiro/steering/enter-test.md".text
        == dv.config.ai.kiro.files.".kiro/steering/enter-test.md".text
        && lib.hasInfix "CONTEXT-TOKEN." dv.config.files."AGENTS.md".text
        && !(lib.hasInfix "enter-test.md" (hmRetirementScript hm))
        && !(lib.hasInfix "enter-test.md" (dvTaskExec dv))
    );

    # Legacy cleanup stays ordered before native file creation only when that
    # task exists; the conditional edge avoids TasksNotFound.
    module-kiro-steering-retire-task-edges = mkTest "kiro-steering-retire-task-edges" (
      let
        bare = evalDevenv {ai.kiro.enable = true;};
        bareTask = bare.config.tasks."ai:kiro:retire-steering-copies" or {};
        withFiles = evalDevenv {
          ai.kiro.enable = true;
          files."probe.txt".text = "probe";
        };
        filesTask = withFiles.config.tasks."ai:kiro:retire-steering-copies" or {};
      in
        bareTask.after
        == ["devenv:files:cleanup"]
        && lib.elem "devenv:enterShell" bareTask.before
        && !(lib.elem "devenv:files" bareTask.before)
        && lib.elem "devenv:files" filesTask.before
    );

    # Consumer definitions replace generated defaults as whole entries; null is
    # a tombstone removed before the backend sink.
    module-kiro-steering-consumer-override-and-tombstone = mkTest "kiro-steering-consumer-override-and-tombstone" (
      let
        cfg = {
          ai.kiro = {
            enable = true;
            context.text = "SYMLINK-CTX-TOKEN.";
            rules.symlinked = {
              matcher = ["src/**"];
              text = "SYMLINK-RULE-TOKEN.";
            };
            files = {
              ".kiro/steering/AGENTS.md".text = "CONSUMER-CONTEXT.";
              ".kiro/steering/symlinked.md" = null;
            };
          };
        };
        hm = evalHm cfg;
        dv = evalDevenv cfg;
        hmEntry = hm.config.home.file.".kiro/steering/AGENTS.md" or null;
        dvContext = dv.config.files."AGENTS.md" or null;
        dvRule = dv.config.files.".kiro/steering/symlinked.md" or null;
      in
        hmEntry
        != null
        && hmEntry.text == "CONSUMER-CONTEXT."
        && !(hm.config.home.file ? ".kiro/steering/symlinked.md")
        && dvContext.text == "SYMLINK-CTX-TOKEN."
        && dvRule == null
    );

    # Kiro HM: top-level ai.rules → a `<name>.md` steering entry with
    # inclusion frontmatter.
    module-kiro-hm-writes-rules-from-top-level = mkTest "kiro-hm-writes-rules-from-top-level" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.rules.testing = {
            matcher = ["**/*.test.*"];
            text = "Write tests for all new features.";
          };
        };
        ruleFile = (kiroSteeringFiles result)."testing.md" or null;
      in
        ruleFile
        != null
        && lib.hasInfix "Write tests for all new features" (ruleFile.text or "")
        && lib.hasInfix "inclusion: fileMatch" (ruleFile.text or "")
    );

    # Root and per-runtime rule entries are keyed pools; the runtime entry
    # atomically replaces a same-key root default.
    module-kiro-hm-rule-runtime-replaces-root = mkTest "kiro-hm-rule-runtime-replaces-root" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rules.same-name.text = "Per-CLI wins.";
          };
          ai.rules.same-name.text = "Top-level loses.";
        };
        rendered = (kiroSteeringFiles result)."same-name.md".text;
      in
        lib.hasInfix "Per-CLI wins." rendered
        && !(lib.hasInfix "Top-level loses." rendered)
    );

    # Devenv parity: Kiro devenv emits ai.rules to steering entries.
    module-kiro-devenv-writes-rules = mkTest "kiro-devenv-writes-rules" (
      let
        result = evalDevenv {
          ai.kiro.enable = true;
          ai.rules.testing = {
            matcher = ["**/*.test.*"];
            text = "Write tests.";
          };
        };
        ruleFile = (kiroSteeringFiles result)."testing.md" or null;
      in
        ruleFile
        != null
        && lib.hasInfix "Write tests" (ruleFile.text or "")
    );

    # HM: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
    module-kiro-hm-top-level-lsp-fanout = mkTest "kiro-hm-top-level-lsp-fanout" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.lspServers.nixd = {
            command = "nixd";
            args = [];
          };
        };
        lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "nixd" (lspFile.text or "")
    );

    # Devenv: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
    module-kiro-devenv-top-level-lsp-fanout = mkTest "kiro-devenv-top-level-lsp-fanout" (
      let
        result = evalDevenv {
          ai.kiro.enable = true;
          ai.lspServers.nixd = {
            command = "nixd";
            args = [];
          };
        };
        lspFile = result.config.files.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "nixd" (lspFile.text or "")
    );

    # HM: per-CLI ai.kiro.lspServers overrides top-level ai.lspServers on
    # name collision. Kiro-specific override wins.
    module-kiro-hm-per-cli-lsp-overrides-top-level = mkTest "kiro-hm-per-cli-lsp-overrides-top-level" (
      let
        result = evalHm {
          ai = {
            kiro.enable = true;
            lspServers.nixd = {
              command = "nixd-top-level";
            };
            kiro.lspServers.nixd = {
              command = "nixd-kiro-specific";
            };
          };
        };
        lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "nixd-kiro-specific" (lspFile.text or "")
        && !(lib.hasInfix "nixd-top-level" (lspFile.text or ""))
    );

    # HM: top-level ai.environmentVariables fans out to the Kiro wrapper.
    #
    # This asserted only that A wrapper appeared, which cannot tell "the
    # top-level value fanned out" apart from "some other trigger wrapped the
    # package" — the fanout, the thing the name promises, went unobserved. HM has
    # no native env surface (the wrapper IS the delivery mechanism), so the value
    # has to be read back out of the shipped script.
    #
    # The sentinel is deliberately distinctive: `grep -F bar` would match store
    # paths incidentally and pass without the fanout ever happening.
    module-kiro-hm-top-level-env-fanout = let
      result = evalHm {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_FOO = "kiro-hm-fanout-sentinel";
      };
    in
      mkWrapperGrepTest {
        name = "kiro-hm-top-level-env-fanout";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["KIRO_FOO" "kiro-hm-fanout-sentinel"];
      };

    # Devenv: top-level ai.environmentVariables fans to the Kiro wrapper.
    module-kiro-devenv-top-level-env-fanout = let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_DEBUG = "kiro-devenv-fanout-sentinel";
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-top-level-env-fanout";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["KIRO_DEBUG" "kiro-devenv-fanout-sentinel"];
      };

    # Devenv: per-CLI ai.kiro.environmentVariables wins over top-level on name
    # collision. `absentNeedles` is the half that matters — the wrapper baking
    # BOTH values would satisfy a presence-only check while leaving which one
    # actually wins undetermined.
    module-kiro-devenv-per-cli-env-wins = let
      result = evalDevenv {
        ai = {
          kiro.enable = true;
          environmentVariables.SHARED = "top-level-loser";
          kiro.environmentVariables.SHARED = "kiro-specific-winner";
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-per-cli-env-wins";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["SHARED" "kiro-specific-winner"];
        absentNeedles = ["top-level-loser"];
      };

    # Kiro HM: package-based declaration renders `${package}/bin/${binary}`.
    # Exercises the package+binary resolution branch.
    module-kiro-hm-lsp-package-command-rendering = mkTest "kiro-hm-lsp-package-command-rendering" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            lspServers.hello-lsp = {
              package = pkgs.hello;
              binary = "hello";
              args = [];
            };
          };
        };
        lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
      in
        lspFile
        != null
        && lib.hasInfix "/bin/hello" (lspFile.text or "")
    );

    # Kiro independence: the top-level `ai.agents` pool carries Claude/Copilot
    # tool NAMES, while Kiro's typed record takes capability TAGS — different
    # vocabularies, so there is no pass-through lowering. Setting ai.agents.foo
    # when ai.kiro.enable = true must NOT produce a .kiro/agents/foo file.
    module-kiro-ignores-top-level-agents = mkTest "kiro-ignores-top-level-agents" (
      let
        result = evalHm {
          ai.kiro.enable = true;
          ai.agents.reviewer = "# Reviewer markdown";
        };
      in
        !(result.config.home.file ? ".kiro/agents/reviewer.json")
        && !(result.config.home.file ? ".kiro/agents/reviewer.md")
    );

    # ── ai.*.rulesDir Dir helper ──────────────────────────────────
    # See lib/ai/dir-helpers.nix + lib/ai/sharedOptions.nix + the
    # per-CLI baseline option in hmTransform/devenvTransform.
    # Plan §4: polymorphic `path | { path, filter? }`, default
    # filter keeps `.md`, basename minus `.md` becomes the key
    # (fixes the `.md.md` doubled-extension bug).

    # Path-only form: `ai.kiro.rulesDir = ./fixtures/kiro-steering;`
    # expands to three steering entries (alpha, beta, gamma). notes.txt
    # is dropped by the default `.md` filter. Keys land at `<name>.md` —
    # no `.md.md` (vacuous-scan negatives inspect the runtime file map).
    module-kiro-rulesdir-path-form = mkTest "kiro-rulesdir-path-form" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rulesDir = ./fixtures/kiro-steering;
          };
        };
        steering = kiroSteeringFiles result;
        hasAlpha = steering ? "alpha.md";
        hasBeta = steering ? "beta.md";
        hasGamma = steering ? "gamma.md";
        # Key is stripped — no `.md.md` name ever emitted.
        noDoubledMd =
          !(lib.any (p: lib.hasSuffix ".md.md" p) (lib.attrNames steering));
        # notes.txt is filtered out (default keeps only `.md`).
        noNotes = !(steering ? "notes.md");
      in
        hasAlpha
        && hasBeta
        && hasGamma
        && noDoubledMd
        && noNotes
    );

    # Submodule form with custom filter (keep only `alpha.md`).
    module-kiro-rulesdir-submodule-filter = mkTest "kiro-rulesdir-submodule-filter" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rulesDir = {
              path = ./fixtures/kiro-steering;
              filter = name: name == "alpha.md";
            };
          };
        };
        steering = kiroSteeringFiles result;
      in
        steering
      ? "alpha.md"
        && !(steering ? "beta.md")
        && !(steering ? "gamma.md")
    );

    # A per-runtime directory-generated entry replaces the same-key root entry.
    module-kiro-rulesdir-entry-replaces-root-single = mkTest "kiro-rulesdir-entry-replaces-root-single" (
      let
        result = evalHm {
          ai.rules.alpha.text = "explicit top-level";
          ai.kiro = {
            enable = true;
            rulesDir = ./fixtures/kiro-steering;
          };
        };
      in
        lib.hasInfix "Alpha steering body." (kiroSteeringFiles result)."alpha.md".text
        && !(lib.hasInfix "explicit top-level" (kiroSteeringFiles result)."alpha.md".text)
    );

    # Devenv-side unscoped directory rules join the shared AGENTS.md.
    module-kiro-devenv-rulesdir-path-form = mkTest "kiro-devenv-rulesdir-path-form" (
      let
        result = evalDevenv {
          ai.kiro = {
            enable = true;
            rulesDir = ./fixtures/kiro-steering;
          };
        };
        agents = result.config.files."AGENTS.md".text;
      in
        lib.hasInfix "<!-- rule: alpha -->" agents
        && lib.hasInfix "<!-- rule: beta -->" agents
        && lib.hasInfix "<!-- rule: gamma -->" agents
        && !(lib.hasInfix "notes" agents)
    );

    # ── sourcePath rollback regression guards ──────────────────────
    # `sourcePath` was introduced in fab4e5c and rolled back in this
    # commit per the ai-factory-collision refactor plan §6 (commit 2).
    # Live-edit is deprecated — devenv covers iteration. `text` is
    # required again; rules always bake into the store with
    # transformer-injected frontmatter.

    # HM: inline rule text still bakes and carries frontmatter in the runtime file
    # entry; the generic sink then preserves that exact entry.
    module-kiro-hm-rule-text-bakes = mkTest "kiro-hm-rule-text-bakes" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rules.my-rule.text = "Inline content";
          };
        };
        entry = (kiroSteeringFiles result)."my-rule.md" or null;
      in
        entry
        != null
        && entry.text != null
        && entry.source == null
        && lib.hasInfix "Inline content" entry.text
    );

    # HM: rule.source is read and baked into the materialized entry.
    module-kiro-hm-rule-path-bakes = mkTest "kiro-hm-rule-path-bakes" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            rules.rule-from-path.source = ./fixtures/kiro-steering/alpha.md;
          };
        };
        entry = (kiroSteeringFiles result)."rule-from-path.md" or null;
      in
        entry
        != null
        && entry.text != null
        && entry.source == null
        && lib.hasInfix "Alpha steering body" entry.text
    );

    # Negative: `sourcePath` is no longer a known option. Attempting to
    # set it fails module evaluation (tryEval captures the error from
    # strict-evaluating only the target rule's attrs, to avoid a full
    # config-tree walk stack overflow).
    module-kiro-hm-rule-sourcepath-rejected = mkTest "kiro-hm-rule-sourcepath-rejected" (
      let
        attempt = builtins.tryEval (let
          r = evalHm {
            ai.kiro = {
              enable = true;
              rules.my-rule = {
                text = "body";
                sourcePath = "/abs/path/to/my-rule.md";
              };
            };
          };
        in
          builtins.deepSeq r.config.ai.kiro.rules.my-rule true);
      in
        !attempt.success
    );
  };
}

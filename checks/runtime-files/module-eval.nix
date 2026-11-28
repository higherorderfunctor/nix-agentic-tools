# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows deliveredFiles deliveredMarkdown deliveredTree evalDevenv evalHm fromGeneratedTree harnessNames mkTest rejectsChange setEnable;
  inherit (import ../../packages/ai-module/lib/files/default.nix {inherit lib pkgs;}) validate;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  fixtureSource = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
  claudeFile = target: entry: {
    ai.claude = {
      enable = true;
      files.${target} = entry;
    };
  };
  # Inspect the exact refusal on the forwarded record, then force the real HM
  # sink: the diagnostic alone would pass if lowering stopped enforcing it.
  hmIssue = config:
    validate {
      backend = "hm";
      files = config.ai.files;
      namespace = "ai";
    };
  # Build-time probes must not realize input that a final file discards.
  unbuildable = name:
    pkgs.runCommand name {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exit 1
    '';
  # A delivered Markdown file's text, from the evaluated `config`.
  markdownOf = config: path:
    if fromGeneratedTree path (deliveredFiles config).${path}
    then deliveredMarkdown {inherit config;} path
    else config.ai.files.${path}.content.text;
in {
  checks = {
    # ── A5a: final per-runtime literal file registry ────────────────────
    # Each runtime/backend can independently lose literal text bytes, source
    # passthrough, or the executable bit while keeping its option declaration.
    module-runtime-files-lower-to-both-backends = let
      runtimeCheck = runtime: backend: evaluate: let
        textTarget = "literal/${runtime}.txt";
        sourceTarget = "literal/${runtime}.source";
        text = "${runtime}-TEXT";
        config = lib.recursiveUpdate (setEnable runtime true) {
          ai.${runtime}.files = {
            ${sourceTarget}.content.source = fixtureSource;
            ${textTarget} = {
              content = {inherit text;};
              executable = true;
            };
          };
        };
        evaluated = evaluate config;
        files = deliveredFiles evaluated.config;
      in
        assert lib.assertMsg (
          evaluated.config.ai.files.${textTarget}.content.text
          == text
          && evaluated.config.ai.files.${sourceTarget}.content.source == fixtureSource
          && files.${textTarget}.executable
          && toString files.${sourceTarget}.source == toString fixtureSource
          && !(files.${sourceTarget} ? text)
        ) "${runtime}/${backend}: literal files must preserve text, source and executable metadata"; ''
          printf '%s\n' ${lib.escapeShellArg "Checking ${runtime}/${backend} literal text"} >&2
          ${pkgs.diffutils}/bin/cmp <(printf '%s' ${lib.escapeShellArg text}) ${lib.escapeShellArg (toString files.${textTarget}.source)}
        '';
      checks = lib.concatMapStrings (runtime:
        lib.concatStrings (lib.mapAttrsToList (runtimeCheck runtime) backends))
      harnessNames;
    in
      pkgs.runCommand "module-test-runtime-files-lower-to-both-backends" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${checks}
        echo PASS > "$out"
      '';

    module-runtime-files-disabled-runtime-does-not-emit = mkTest "runtime-files-disabled-runtime-does-not-emit" (
      let
        target = "literal/probe";
        entry.content.text = "DECLARED-BUT-DISABLED";
        switchedOff = (evalDevenv (claudeFile target {enable = false;})).config;
        rows = backend: evaluate: let
          dormant = (evaluate {ai.claude.files.${target} = entry;}).config;
          enabled = (evaluate (claudeFile target entry)).config;
          delivered = config: deliveredFiles config ? ${target};
        in {
          "${backend}: disabled runtime must not forward its otherwise valid literal" =
            dormant.ai.claude.files.${target}.content.text
            == "DECLARED-BUT-DISABLED"
            && !(dormant.ai.files ? ${target})
            && !(delivered dormant)
            && delivered enabled;
        };
      in
        checkRows "runtime and literal enable gates" (
          lib.mergeAttrsList (lib.mapAttrsToList rows backends)
          // {
            "devenv: switching off a literal must not require content or deliver a file" =
              !switchedOff.ai.claude.files.${target}.enable && !(deliveredFiles switchedOff ? ${target});
          }
        )
    );

    module-runtime-files-invalid-targets-rejected = mkTest "runtime-files-invalid-targets-rejected" (
      let
        target = "literal/probe";
        text = {content.text = "probe";};
        evaluate = path: (evalHm (claudeFile path text)).config;
        valid = evaluate target;
        rejectsTarget = path: let
          invalid = evaluate path;
        in
          hmIssue invalid
          == ''files."${path}": target must be a normalized relative path without empty, . or .. segments''
          && rejectsChange (config: config.home.file ? ${target}) {
            inherit valid invalid;
            expected = true;
          };
      in
        checkRows "runtime file targets" {
          "parent segment is not resolved before validation" = rejectsTarget "parent/../escape";
        }
    );

    module-runtime-files-content-shape-rejected = mkTest "runtime-files-content-shape-rejected" (
      let
        target = "literal/probe";
        evaluate = entry: (evalHm (claudeFile target entry)).config;
        delivered = config: config.home.file ? ${target};
        disabled = evaluate {enable = false;};
        applyCommand = config: config.home.activation.ai-files-apply.text or "";
        # Force the native link map without walking its derivations. The apply
        # command must differ from the disabled control even without a native link.
        reachesSink = config:
          builtins.seq (delivered config) (let
            command = applyCommand config;
          in
            lib.hasInfix "--phase apply" command && command != applyCommand disabled);
        textEntry = {content.text = "probe";};
        runEntry = {
          content.run = "printf '{}'";
          method = "ro";
        };
        # Equal-priority alternatives are rejected by the shared content
        # selection, not by a method/format constraint on one of the forms.
        rejectsTie = alternatives: valid: content: let
          invalid = evaluate (lib.recursiveUpdate valid {inherit content;});
        in
          hmIssue invalid
          == ''files."${target}": content alternatives tie at priority 100: ${alternatives}''
          && rejectsChange reachesSink {
            inherit invalid;
            valid = evaluate valid;
            expected = true;
          };
      in
        checkRows "runtime file content restrictions" {
          "equal-priority run and text must not prefer the renderer" = rejectsTie "run, text" runEntry textEntry.content;
          "equal-priority run and value must not prefer structured data" = rejectsTie "run, value" (runEntry // {format = "json";}) {value.probe = true;};
          # An entry with `text` at the top level has not been migrated;
          # accepting it would deliver a file with no bytes.
          "retired flat text field is not a runtime file option" = rejectsChange (config: config.ai.claude.files.${target}.content.text) {
            valid = evaluate textEntry;
            invalid = evaluate {text = "probe";};
            expected = "probe";
          };
        }
    );

    module-runtime-files-shared-agentsmd-arbitration = mkTest "runtime-files-shared-agentsmd-arbitration" (
      let
        # The consumerOnly* cases have NO generated context, so Kimchi never
        # registers its generated shared target. A consumer-authored final
        # AGENTS.md must still arbitrate with Codex's, land alone, suppress,
        # and reject a text-versus-suppression conflict. Ported from #1849.
        consumerOnly = kimchiEntry:
          evalDevenv {
            ai = {
              codex = {
                enable = true;
                files."AGENTS.md" = {
                  enable = true;
                  content.text = "CONSUMER-ONLY";
                };
              };
              kimchi = {
                enable = true;
                files."AGENTS.md" = kimchiEntry;
              };
            };
          };
        consumerAgreement = (consumerOnly {content.text = "CONSUMER-ONLY";}).config;
        standaloneKimchi = entry: context:
          evalDevenv {
            ai.kimchi = {
              enable = true;
              files."AGENTS.md" = entry;
              context = {filename = "custom.md";} // context;
            };
          };
        kimchiConsumerOnly = standaloneKimchi {content.text = "KIMCHI-CONSUMER-ONLY";} {};
        # Generated Kimchi context beside a custom (Home Manager) filename. The
        # devenv factory still writes AGENTS.md, so a public override on that
        # path must arbitrate with the shared owner rather than fail its
        # aggregate assertion for a context.filename that names another file.
        kimchiContextOverride = standaloneKimchi {content.text = "KIMCHI-CONTEXT-OVERRIDE";} {text = "KIMCHI-GENERATED";};
        consumerOnlySuppressed = standaloneKimchi {enable = false;} {};
        # Identical to consumerOnly except Kimchi suppresses instead of
        # agreeing. The rejection is pinned to its cause: the merged `enable`
        # throws, and the definitions reaching it are exactly one suppression
        # and one enabled text, so an unrelated evaluation failure cannot pass
        # for this one.
        consumerSuppressionConflict = (consumerOnly {enable = false;}).config;
        rejectsSuppression = read: expected:
          rejectsChange read {
            valid = consumerAgreement;
            invalid = consumerSuppressionConflict;
            inherit expected;
          };
      in
        checkRows "shared AGENTS.md arbitration" {
          "explicit enable and suppression conflict at the merged leaf and sink" =
            rejectsSuppression (config: config.ai.files."AGENTS.md".enable) true
            && rejectsSuppression (config: (deliveredFiles config) ? "AGENTS.md") true;
          "Kimchi consumer suppression does not emit either name" =
            !((deliveredFiles consumerOnlySuppressed.config) ? "AGENTS.md")
            && !((deliveredFiles consumerOnlySuppressed.config) ? "custom.md");
          "Kimchi generated context can be overridden despite a custom HM filename" =
            markdownOf kimchiContextOverride.config "AGENTS.md"
            == "KIMCHI-CONTEXT-OVERRIDE"
            && lib.all (assertion: assertion.assertion) kimchiContextOverride.config.assertions;
          "Kimchi standalone consumer text is delivered at the shared path" =
            markdownOf kimchiConsumerOnly.config "AGENTS.md"
            == "KIMCHI-CONSUMER-ONLY"
            && !((deliveredFiles kimchiConsumerOnly.config) ? "custom.md");
        }
    );

    module-runtime-files-shared-agentsmd-ignores-disabled-runtime = mkTest "runtime-files-shared-agentsmd-ignores-disabled-runtime" (
      let
        withDormantEntry = {
          activeRuntime,
          dormantRuntime,
          entry,
        }:
          evalDevenv (lib.recursiveUpdate (setEnable activeRuntime true) {
            ai = {
              context.text = "ACTIVE-SHARED-CONTEXT";
              ${dormantRuntime}.files."AGENTS.md" = entry;
            };
          });
        ignores = activeRuntime: dormantRuntime: entry: let
          inherit (withDormantEntry {inherit activeRuntime dormantRuntime entry;}) config;
          delivered = markdownOf config "AGENTS.md";
        in
          lib.hasInfix "ACTIVE-SHARED-CONTEXT" delivered && !(lib.hasInfix "DORMANT-" delivered);
      in
        checkRows "disabled runtimes must not participate in shared arbitration" {
          "Codex null entry must not suppress active Kimchi context" = ignores "kimchi" "codex" null;
          "Kimchi text must not override active Codex context" = ignores "codex" "kimchi" {content.text = "DORMANT-KIMCHI";};
          "Kiro null entry must not suppress active Codex context" = ignores "codex" "kiro" null;
        }
    );

    # Layer-1 replacements discard oversized generated content unread, and
    # suppression removes delivery. Generated defaults retain their byte limit;
    # consumer content bypasses that generated-tree guard.
    module-runtime-files-byte-limit-follows-final-entry = let
      oversized = lib.concatStrings (lib.replicate 64 "x");
      override = evaluate: target: contextPath: entry:
        evaluate {
          ai = lib.recursiveUpdate (lib.setAttrByPath contextPath oversized) {
            codex = {
              enable = true;
              files.${target} = entry;
              projectDocMaxBytes = 8;
            };
          };
        };
      overrideHm = override evalHm ".codex/AGENTS.md" ["codex" "context" "text"];
      overrideDevenv = override evalDevenv "AGENTS.md" ["context" "text"];
      # Longer than the configured limit: checking a short replacement would
      # also pass if the generated-tree guard were applied to consumer bytes.
      replacementText = "consumer replacement";
      replacement.content.text = replacementText;
      hmReplacement = overrideHm replacement;
      hmDisabled = overrideHm {enable = false;};
      devenvReplacement = overrideDevenv replacement;
      devenvDisabled = overrideDevenv {enable = false;};
      passes = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
      hmFile = hmReplacement.config.home.file.".codex/AGENTS.md";
      devenvFile = (deliveredFiles devenvReplacement.config)."AGENTS.md";
    in
      assert lib.assertMsg (lib.all passes [hmReplacement hmDisabled devenvReplacement devenvDisabled])
      "runtime-files-byte-limit-follows-final-entry: a fixture fails its assertions";
      assert lib.assertMsg (hmReplacement.config.ai.codex._maxBytes.".codex/AGENTS.md".bytes == 8)
      "runtime-files-byte-limit-follows-final-entry: the Home Manager replacement's path lost its limit";
      assert lib.assertMsg (devenvFile.text == replacementText)
      "runtime-files-byte-limit-follows-final-entry: the shared copy lost the consumer bytes";
        pkgs.runCommand "module-test-runtime-files-byte-limit-follows-final-entry" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${pkgs.diffutils}/bin/cmp <(printf '%s' ${lib.escapeShellArg replacementText}) ${lib.escapeShellArg (toString hmFile.source)}
          echo PASS > "$out"
        '';

    module-runtime-files-discarded-codex-source-stays-lazy = mkTest "runtime-files-discarded-codex-source-stays-lazy" (
      let
        source = unbuildable "discarded-codex-context-must-not-build";
        fixture = evaluate: runtime: target: entry:
          (evaluate (lib.recursiveUpdate (setEnable runtime true) {
            ai = {
              context = {inherit source;};
              ${runtime} = {
                context.text = "RUNTIME-CONTEXT";
                files.${target} = entry;
              };
            };
          })).config;
        replaced = evaluate: target: text:
          markdownOf (fixture evaluate "codex" target {content = {inherit text;};}) target == text;
        disabled = evaluate: runtime: target:
          !(deliveredFiles (fixture evaluate runtime target {enable = false;}) ? ${target});
      in
        checkRows "final file must not read discarded context source" {
          "devenv Codex suppression" = disabled evalDevenv "codex" "AGENTS.md";
          "home-manager Codex replacement" = replaced evalHm ".codex/AGENTS.md" "HM-REPLACEMENT";
          "home-manager Codex suppression" = disabled evalHm "codex" ".codex/AGENTS.md";
          "home-manager Kiro suppression" = disabled evalHm "kiro" ".kiro/steering/AGENTS.md";
        }
    );

    module-runtime-files-generated-empty-codex-source-omitted = mkTest "runtime-files-generated-empty-codex-source-omitted" (
      let
        source = ../../lib/testing/fixtures/empty;
        omitted = evaluate: runtime: target: let
          evaluated = evaluate (lib.recursiveUpdate (setEnable runtime true) {ai.context = {inherit source;};});
        in
          !(deliveredFiles evaluated.config ? ${target});
      in
        checkRows "empty context must not produce a document" {
          "devenv Codex does not emit an empty shared document even with its limit" = omitted evalDevenv "codex" "AGENTS.md";
          "devenv Kiro does not contribute an empty document to the shared owner" = omitted evalDevenv "kiro" "AGENTS.md";
          "home-manager Codex does not emit an empty native document" = omitted evalHm "codex" ".codex/AGENTS.md";
        }
    );

    # Content at `mkDefault` is still content: the leaf-default idiom a
    # downstream module uses for an overridable file must deliver it, not
    # leave a record that nothing writes and nothing reports. A layer-1 entry
    # lands as its own bytes, outside the generated tree.
    module-runtime-files-default-priority-content-delivers = mkTest "runtime-files-default-priority-content-delivers" (
      let
        sourcePath = "literal/default-source.md";
        textPath = "literal/default-text.md";
        config.ai.claude = {
          enable = true;
          files = {
            ${sourcePath}.content.source = lib.mkDefault fixtureSource;
            ${textPath}.content.text = lib.mkDefault "DEFAULT-TEXT";
          };
        };
        rows = backend: evaluate: let
          evaluated = evaluate config;
          files = deliveredFiles evaluated.config;
        in {
          "${backend}: default-priority source must not be dropped or rendered as text" =
            toString files.${sourcePath}.source == toString fixtureSource;
          "${backend}: default-priority text must reach the native sink" =
            toString files.${textPath}.source
            != ""
            && evaluated.config.ai.files.${textPath}.content.text == "DEFAULT-TEXT";
        };
      in
        checkRows "literal content at default priority" (lib.mergeAttrsList (lib.mapAttrsToList rows backends))
    );

    # Entry enable gates each engine content shape, including a structured
    # value that has only a default-priority child.
    module-runtime-files-disable-suppresses-every-form = mkTest "runtime-files-disable-suppresses-every-form" (
      let
        path = ".kiro/probe.json";
        rows = backend: evaluate: let
          check = entry: enable: let
            inherit
              (evaluate {
                ai.kiro = {
                  cli.enable = true;
                  files.${path} =
                    entry
                    // {
                      enable = lib.mkForce enable;
                      format = "json";
                    };
                };
              })
              config
              ;
            files = deliveredFiles config;
            source = files.${path}.source or null;
          in
            config.ai.files.${path}.enable
            == enable
            && (
              if !enable
              then !(files ? ${path})
              else if entry.content ? run
              then (files.${path}.run or null) == "printf '{}'"
              else source != null && builtins.isString (toString source)
            );
          structured = value: {
            content.value.a = value;
            method = "symlink";
          };
          renderer = {
            content.run = "printf '{}'";
            method = "ro";
          };
        in {
          "${backend}: disabled default-priority structured child cannot still link" = check (structured (lib.mkDefault true)) false;
          "${backend}: disabled renderer cannot still reach the engine" = check renderer false;
          "${backend}: disabled structured value cannot still link" = check (structured true) false;
          "${backend}: enabled renderer must reach the engine unchanged" = check renderer true;
          "${backend}: enabled structured value must still link" = check (structured true) true;
          "${backend}: default-priority structured child must still link" = check (structured (lib.mkDefault true)) true;
        };
      in
        checkRows "structured and render-time runtime files" (lib.mergeAttrsList (lib.mapAttrsToList rows backends))
    );

    # A store-backed replacement of the shared AGENTS.md stays lazy: its size
    # limit is measured when its generated tree is built, never by reading it
    # during evaluation. The source is a derivation that fails to build.
    module-runtime-files-shared-agentsmd-source-stays-lazy = mkTest "runtime-files-shared-agentsmd-source-stays-lazy" (
      let
        source = unbuildable "shared-agents-md-source-must-not-build";
        evaluated = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.source = source;
              projectDocMaxBytes = 8;
            };
            context.text = "SHARED-CONTEXT";
          };
        };
      in
        builtins.all (assertion: assertion.assertion) evaluated.config.assertions
        && (deliveredFiles evaluated.config)."AGENTS.md".source == toString source
    );

    module-runtime-files-discarded-composed-context-stays-lazy = mkTest "runtime-files-discarded-composed-context-stays-lazy" (
      let
        source = unbuildable "discarded-runtime-contexts-must-not-build";
        fixture = evaluate: runtime: target: entry: extras:
          (evaluate {
            ai = {
              context = {inherit source;};
              ${runtime} =
                {
                  context.text = "RUNTIME-CONTEXT";
                  enable = true;
                  files.${target} = entry;
                }
                // extras;
            };
          }).config;
        claudePath = ".claude/CLAUDE.md";
        hmKimchiPath = ".config/kimchi/harness/AGENTS.md";
        # Instantiating a replacement instantiates its required tree: check the
        # native sink source, not just the public override's text.
        nativeText = config: path:
          assert lib.assertMsg (toString (deliveredFiles config).${path}.source != "") "${path} has no native source";
            config.ai.files.${path}.content.text;
        claudeReplacement = evaluate:
          nativeText (fixture evaluate "claude" claudePath {content.text = "CLAUDE-REPLACEMENT";} {}) claudePath
          == "CLAUDE-REPLACEMENT";
        # Leave a live rule in the tree so that suppressing context cannot
        # make the assertion pass by skipping tree instantiation entirely.
        claudeOff = evaluate: let
          config = fixture evaluate "claude" claudePath {enable = false;} {rules.probe.text = "probe";};
        in
          !(deliveredFiles config ? ${claudePath})
          && builtins.isString config.ai.claude._generatedTree.drvPath;
        hmKimchi = fixture evalHm "kimchi" hmKimchiPath {content.text = "KIMCHI-REPLACEMENT";} {};
        shared = (deliveredFiles (fixture evalDevenv "kimchi" "AGENTS.md" {content.text = "KIMCHI-REPLACEMENT";} {}))."AGENTS.md";
      in
        checkRows "discarded composed context must not realize its source" {
          "devenv Claude replacement instantiates the native sink" = claudeReplacement evalDevenv;
          "devenv Claude suppression leaves the rules tree instantiable" = claudeOff evalDevenv;
          "devenv Kimchi replacement is copied by the shared owner" =
            shared.method == "ro" && shared.text == "KIMCHI-REPLACEMENT";
          "home-manager Claude replacement instantiates the native sink" = claudeReplacement evalHm;
          "home-manager Claude suppression leaves the rules tree instantiable" = claudeOff evalHm;
          "home-manager Kimchi replacement stays a native symlink" =
            nativeText hmKimchi hmKimchiPath
            == "KIMCHI-REPLACEMENT"
            && hmKimchi.ai.files.${hmKimchiPath}.method == "symlink";
        }
    );

    # A wildcard or wrong-runtime dispatcher would give these checks an extra
    # file, the wrong path, or the wrong runtime even though their tree builds.
    module-ai-checks-routes-files-by-surface = let
      expectRoute = runtime: path: marker: ''
        test "$AI_RUNTIME" = ${lib.escapeShellArg runtime}
        test "$#" = 1
        test "$1" = ${lib.escapeShellArg path}
        test -f "$1"
        touch ${lib.escapeShellArg marker}
      '';
      evaluated = evalDevenv {
        ai = {
          checks = {
            context = expectRoute "claude" ".claude/CLAUDE.md" ".context-check-ran";
            rules = expectRoute "claude" ".claude/rules/probe.md" ".rules-check-ran";
            # A comment-only consumer check must not make the generated script
            # a syntax error. The skills fixture makes the tree run this check.
            skills = "# comment-only check";
          };
          claude = {
            enable = true;
            skills.probe = ../../packages/ai-module/checks/fixtures/probe-skill;
          };
          context.text = "probe";
          rules.probe.text = "probe";
        };
      };
      tree = deliveredTree evaluated ".claude/rules/probe.md";
      internal = evalDevenv {
        ai = {
          checks.context = expectRoute "internal" "AGENTS.md" ".context-check-ran";
          codex.enable = true;
          context.text = "probe";
        };
      };
      internalTree = deliveredTree internal "AGENTS.md";
    in
      pkgs.runCommand "module-test-ai-checks-routes-files-by-surface" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        require_marker() {
          if ! test -e "$1"; then
            printf 'Generated-file check did not create %s\n' "$1" >&2
            return 1
          fi
        }
        require_marker ${tree}/.context-check-ran
        require_marker ${tree}/.rules-check-ran
        test -f ${tree}/.claude/skills/probe/SKILL.md
        require_marker ${internalTree}/.context-check-ran
        touch "$out"
      '';

    # A bare failure would hide which generated-file check exited and why.
    module-ai-checks-failure-names-surface-and-runtime = let
      evaluated = evalDevenv {
        ai = {
          checks.skills = "exit 7";
          claude = {
            enable = true;
            skills.probe = ../../packages/ai-module/checks/fixtures/probe-skill;
          };
        };
      };
      expectedFailure = pkgs.testers.testBuildFailure evaluated.config.ai.claude._generatedTree;
    in
      pkgs.runCommand "module-test-ai-checks-failure-names-surface-and-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        grep -q -F 'Generated-file check failed for surface skills in runtime claude (exit 7)' ${expectedFailure}/testBuildFailure.log
        touch "$out"
      '';

    # An empty runtime tier suppresses the inherited check for one surface,
    # without dropping the generated file or unsetting other root checks.
    module-ai-checks-tier-replacement = let
      fixture = {
        ai = {
          checks = {
            all = "exit 1";
            # Nix-installed Claude always has settings, independent of rules.
            settings = ''
              test "$AI_RUNTIME" = claude
              test "$#" = 1
              test "$1" = .claude/settings.json
              ${pkgs.jq}/bin/jq -e '. == {
                "$schema": "https://json.schemastore.org/claude-code-settings.json",
                "env": {"DISABLE_AUTOUPDATER": "1"}
              }' "$1" >/dev/null
              touch .settings-check-ran
            '';
          };
          claude.enable = true;
          gitSshConfigWorkaround = false;
          rules.probe.text = "probe";
        };
      };
      replaced =
        (evalDevenv (lib.recursiveUpdate fixture {
          ai.claude.checks.rules = "";
        })).config;
      inherited = (evalDevenv fixture).config;
      expectedFailure = pkgs.testers.testBuildFailure inherited.ai.claude._generatedTree;
    in
      assert replaced.ai.claude.checks.rules == "";
      assert inherited.ai.claude.checks.rules == "exit 1";
        pkgs.runCommand "module-test-ai-checks-tier-replacement" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          test -e ${replaced.ai.claude._generatedTree}/.claude/rules/probe.md
          test -e ${replaced.ai.claude._generatedTree}/.settings-check-ran
          grep -q -F 'Generated-file check failed for surface rules in runtime claude (exit 1)' ${expectedFailure}/testBuildFailure.log
          touch "$out"
        '';

    module-ai-checks-stamp-coverage = mkTest "ai-checks-stamp-coverage" (
      let
        specimen = import ./specimen.nix {inherit lib;};
        # Pin a required stamp for each runtime and backend with generated
        # files, so an empty inventory cannot pass. Copilot has no HM tree.
        required = {
          devenv = {
            claude.".claude/CLAUDE.md" = "context";
            codex.".codex/config.toml" = "settings";
            copilot.".github/copilot-instructions.md" = "context";
            kimchi.".kimchi/mcp.json" = "mcpServers";
            kiro.".kiro/steering/scoped.md" = "rules";
          };
          hm = {
            claude.".claude/CLAUDE.md" = "context";
            codex.".codex/AGENTS.md" = "context";
            copilot = {};
            kimchi.".config/kimchi/harness/AGENTS.md" = "context";
            kiro.".kiro/steering/AGENTS.md" = "context";
          };
        };
        rows = mode: evaluate: runtime: let
          entries = (evaluate (specimen mode runtime)).config.ai.${runtime}._generatedFiles;
        in
          lib.mapAttrs' (path: entry: lib.nameValuePair "${runtime}/${mode}/${path} has no surface stamp" (entry.surface != null)) entries
          // lib.mapAttrs' (path: surface:
            lib.nameValuePair "${runtime}/${mode}/${path} must be stamped ${surface}" (
              (entries.${path}.surface or null) == surface
            ))
          required.${mode}.${runtime};
        runtimeRows = lib.concatMap (runtime: [(rows "devenv" evalDevenv runtime) (rows "hm" evalHm runtime)]) harnessNames;
      in
        checkRows "generated-file surface stamps" (lib.mergeAttrsList runtimeRows)
    );
  };
}

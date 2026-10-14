{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  # lib/testing/module-harness.nix declares `warnings` in both backend stubs,
  # so this reads the module-system branch of mkBackendTransform rather than
  # extending the eval to create the option a real backend always has.
  evaluate = mode: config:
    (
      if mode == "hm"
      then harness.evalHm config
      else harness.evalDevenv config
    )
    .config
    .warnings;
  inherit
    (import ../../lib/ai/option-paths.nix {
      lib = harness.hmLib;
      inherit pkgs;
    })
    records
    ;
  declaredPaths = lib.genAttrs policy.modes (mode:
    map (option: option.loc) (lib.optionAttrSetToDocList
      (
        if mode == "hm"
        then harness.evalHm {}
        else harness.evalDevenv {}
      ).options));
  # Refuse an inputOptions path that is not a declared option, including the
  # retired ai.kiro.native.settings and ai.kiro.environmentVariables paths.
  inputsDeclared = lib.all (row:
    lib.all (path:
      lib.assertMsg (builtins.elem path declaredPaths.${row.mode})
      "delivery row ${policy.key row}: inputOptions path ${lib.showOption path} is not a declared option")
    (row.inputOptions or [])) (lib.concatMap policy.writersOf policy.rows);
  contains = needle: messages: lib.any (lib.hasInfix needle) messages;
  sample = {
    agents.probe = {
      description = "probe";
      instructions.text = "probe";
    };
    context.text = "probe";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    lspServers.probe = {
      command = "probe";
      extensions = ["nix"];
    };
    mcpServers.probe.command = "probe";
    permissions = [
      {
        capability = "shell";
        effect = "allow";
      }
    ];
    rules.probe.text = "probe";
    settings.model = "probe";
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  # Every absent or inert primary row gets a populated request and an empty
  # control through the actual factory. Unsupported runtime options use root.
  gaps = lib.filter (row: row.primitive == "notApplicable" || row ? deliveryGap) policy.rows;
  rowCase = row: let
    enabled = harness.setEnable row.ecosystem true;
    empty = evaluate row.mode enabled;
    messagesFor = path: evaluate row.mode (lib.recursiveUpdate enabled (lib.setAttrByPath path sample.${row.surface}));
    warns = path: let
      messages = messagesFor path;
      needle = "${lib.showOption path} is set but ${row.mode} does not deliver it to ${row.ecosystem} (reason: ${row.deliveryGap or row.reason})";
    in
      builtins.elem needle messages
      && !(builtins.elem needle empty);
    path =
      if row.surface == "settings"
      then ["ai" row.ecosystem "native" "settings"]
      else if row.surface == "permissions"
      then ["ai" row.ecosystem "permissions"]
      else ["ai" row.surface];
  in
    # No permissions option or translation exists for these runtimes, so there
    # is nothing to probe. Assert the EMPTY input list rather than skipping the
    # row: a row that later grows an input option then stops passing by
    # default instead of staying silently unexercised.
    if row.surface == "permissions" && row.ecosystem != "kiro"
    then row.inputOptions == []
    else warns path;
  # `ai.kiro.cli.trustedMcpTools` is NOT a case here: the wrapper appends
  # `--trust-tools` on both backends, so a devenv consumer setting it has no
  # delivery gap to be told about. The narrower withhold it does have — the v3
  # `acp` arm and Darwin's bundle-discovery launcher — is asserted by
  # ai-warnings-darwin-trust below.
  #
  cases =
    [
      {
        runtime = "copilot";
        path = ["ai" "copilot" "context"];
        value.text = "probe";
        mode = "hm";
      }
      {
        runtime = "copilot";
        path = ["ai" "copilot" "rules"];
        value.probe.text = "probe";
        mode = "hm";
      }
    ]
    # A normalized `tools` list is Claude/Copilot tool names; runtimes with
    # another vocabulary drop it and say so at the path that set it.
    ++ map (runtime: {
      inherit runtime;
      path = ["ai" "agents" "probe"];
      value = sample.agents.probe // {tools = ["Read"];};
      suffix = ".tools";
    }) ["codex" "kimchi" "kiro"]
    ++ [
      {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value = {
          url = "https://example.invalid";
          args = ["lost"];
        };
        suffix = ".args";
      }
      {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value = {
          command = "probe";
          settings.lost = true;
        };
        suffix = ".settings";
      }
    ]
    ++ lib.concatMap (http:
      map (field: {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value =
          (
            if http
            then {url = "https://example.invalid";}
            else {command = "probe";}
          )
          // {
            ${field} =
              {
                args = ["probe"];
                command = "probe";
                env.PROBE = "";
                headers.Authorization = "";
                package = pkgs.hello;
                settings.probe = true;
                timeout = 1;
              }.${
                field
              };
          };
        suffix = ".${field}";
      }) (
        if http
        then ["args" "command" "env" "package" "settings"]
        else ["headers" "settings" "timeout"]
      )) [false true]
    ++ map (surface: {
      runtime = "claude";
      path = ["ai" "claude" surface];
      value =
        if surface == "unpinLaunchEffort"
        then {probe = true;}
        else {probe = pkgs.emptyDirectory;};
    }) ["plugins" "unpinLaunchEffort"]
    ++ [
      {
        runtime = "kiro";
        path = ["ai" "rules" "probe"];
        value = {
          text = "probe";
          inclusion = ["manual"];
        };
        suffix = ".inclusion";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "probe"];
        value = {
          text = "probe";
          inclusion = "manual";
        };
        suffix = ".inclusion";
      }
      # A consumer key may contain a dot of its own: `foo.bar.md` lands at key
      # `foo.bar`. The rendered path has to quote it, or the message names an
      # option that does not exist and cannot be pasted back.
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "foo.bar"];
        value = {
          text = "probe";
          inclusion = "manual";
        };
        suffix = ".inclusion";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            type = "agent";
            prompt = {text = "probe";};
          };
          timeout = 1;
        };
        suffix = ".timeout";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            type = "agent";
            prompt = {text = "probe";};
            command = "true";
          };
        };
        suffix = ".action.command";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            command = "true";
            prompt = {text = "probe";};
          };
        };
        suffix = ".action.prompt";
      }
    ]
    # Copilot's devenv delivery is partial: the repository `effortLevel` it
    # lowers to reaches only the interactive session, because `-p`, `--acp`
    # and `--server` read effort from the user settings file. So the request
    # warns at whichever path supplied it.
    ++ map (path: {
      runtime = "copilot";
      inherit path;
      value = "high";
    }) [
      ["ai" "settings" "reasoningEffort"]
      ["ai" "copilot" "settings" "reasoningEffort"]
    ];
  rootGapRequests = [
    {
      modes = ["hm"];
      runtime = "copilot";
      surface = "context";
    }
    {
      runtime = "claude";
      surface = "environmentVariables";
    }
    {
      runtime = "copilot";
      surface = "hooks";
    }
    {
      modes = ["hm"];
      runtime = "kimchi";
      surface = "hooks";
    }
    {
      runtime = "codex";
      surface = "lspServers";
    }
    {
      runtime = "kimchi";
      surface = "lspServers";
    }
  ];
  gapCases =
    lib.concatMap (request:
      map (mode: {
        inherit mode;
        inherit (request) runtime;
        path = ["ai" request.surface];
        reason = policy.definitions.${request.surface}.${request.runtime}.${mode}.reason;
        value = sample.${request.surface};
      }) (request.modes or ["devenv" "hm"]))
    rootGapRequests
    ++ lib.concatMap (mode:
      map (runtime: {
        inherit mode runtime;
        path = ["ai" "shell"];
        reason = "${runtime}'s supportedPools excludes shell; its runtime record does not consume this shared surface.";
        value = pkgs.bash;
      }) ["copilot"]
      ++ [
        {
          inherit mode;
          path = ["ai" "hooks"];
          reason = "Kiro's v3 trigger schema has no lossless mapping from portable command hooks; its native hooks are a separate surface (packages/kiro-cli/lib/mkKiro.nix).";
          runtime = "kiro";
          value = sample.hooks;
        }
        {
          inherit mode;
          count = 1;
          path = ["ai" "settings"];
          reason = "Kiro persists effort only in per-model chat.modelDefaults records; shared reasoningEffort has no lossless target. Use ai.kiro.cli.native.settings.chat.modelDefaults.<model>.effort for the native per-model value (packages/kiro-cli/lib/mkKiro.nix).";
          runtime = "kiro";
          value.reasoningEffort = "high";
        }
      ]) ["devenv" "hm"]
    ++ [
      {
        mode = "devenv";
        path = ["ai" "hooks" "PermissionRequest"];
        reason = "Kimchi's lifecycle event list has no PermissionRequest event; projectHooksFor filters it out (packages/kimchi/lib/mkKimchi.nix).";
        runtime = "kimchi";
        value = sample.hooks.PreToolUse;
      }
    ];
  consumedRootsQuiet = lib.all (mode:
    lib.all (case:
      evaluate mode (lib.recursiveUpdate (harness.setEnable case.runtime true)
        (lib.setAttrByPath case.path case.value))
      == []) [
      {
        path = ["ai" "context"];
        runtime = "claude";
        value = sample.context;
      }
      {
        path = ["ai" "environmentVariables"];
        runtime = "codex";
        value = sample.environmentVariables;
      }
      {
        path = ["ai" "hooks"];
        runtime = "claude";
        value = sample.hooks;
      }
      {
        path = ["ai" "hooks" "PermissionRequest"];
        runtime = "claude";
        value = sample.hooks.PreToolUse;
      }
      {
        path = ["ai" "lspServers"];
        runtime = "copilot";
        value = sample.lspServers;
      }
      {
        path = ["ai" "settings" "reasoningEffort"];
        runtime = "kimchi";
        value = "high";
      }
      {
        path = ["ai" "shell"];
        runtime = "codex";
        value = pkgs.bash;
      }
      {
        path = ["ai" "shell"];
        runtime = "kimchi";
        value = pkgs.bash;
      }
    ]) ["devenv" "hm"];
  # Supported effort delivery stays quiet; withholding Copilot's native
  # repository value also withdraws its partial-delivery warning.
  effortSilent = lib.all ({
    runtime,
    modes,
    paths,
    extra ? {},
  }:
    lib.all (mode:
      lib.all (path: let
        enabled = lib.recursiveUpdate (harness.setEnable runtime true) extra;
      in
        evaluate mode (lib.recursiveUpdate enabled (lib.setAttrByPath path "high"))
        == evaluate mode enabled)
      paths)
    modes) [
    {
      runtime = "copilot";
      modes = ["hm"];
      paths = [
        ["ai" "settings" "reasoningEffort"]
        ["ai" "copilot" "settings" "reasoningEffort"]
      ];
    }
    {
      runtime = "copilot";
      modes = ["devenv"];
      paths = [
        ["ai" "settings" "reasoningEffort"]
        ["ai" "copilot" "settings" "reasoningEffort"]
      ];
      extra.ai.copilot.native.settings.effortLevel = null;
    }
    {
      runtime = "kimchi";
      modes = ["devenv" "hm"];
      paths = [
        ["ai" "settings" "reasoningEffort"]
        ["ai" "kimchi" "settings" "reasoningEffort"]
      ];
    }
  ];
  # Copilot and Kiro both render an LSP server's `extensions` (Copilot as
  # `fileExtensions`, Kiro as `file_extensions`), on both backends and at both
  # the root and the per-runtime path, so no warning may name that field: it
  # would claim a gap the factory closes.
  #
  # Beyond that field, a cell warns exactly when the policy records a gap for
  # it. rowCase owns the cells that record one; here, a cell that records none
  # must stay silent. That silence says the warnings match the policy, NOT that
  # every file is read: Kiro's Home Manager copy lands at
  # $HOME/.kiro/settings/lsp.json and is live only when the workspace is $HOME
  # (mkKiro.nix), yet `lspServers/kiro/hm` records no gap. Recording one moves
  # that cell to rowCase rather than failing this assertion.
  deliveredLspSilent = lib.all (mode:
    lib.all (runtime: let
      recordedGap = lib.any (row: row.surface == "lspServers" && row.ecosystem == runtime && row.mode == mode) gaps;
    in
      lib.all (path: let
        messages = evaluate mode (lib.recursiveUpdate (harness.setEnable runtime true) (lib.setAttrByPath path {
          command = "probe";
          extensions = ["nix"];
        }));
      in
        !contains (lib.showOption (path ++ ["extensions"])) messages
        && (recordedGap || messages == []))
      [
        ["ai" "lspServers" "probe"]
        ["ai" runtime "lspServers" "probe"]
      ])
    ["copilot" "kiro"]) ["devenv" "hm"];
  caseMode = case: case.mode or "devenv";
  # Memoize identical enabled-empty controls across both case collections.
  emptyCaseWarnings = lib.mapAttrs (mode: modeCases:
    lib.genAttrs (map (case: case.runtime) modeCases)
    (runtime: evaluate mode (harness.setEnable runtime true)))
  (lib.groupBy caseMode (cases ++ gapCases));
  casePass = case: let
    mode = caseMode case;
    input = lib.setAttrByPath case.path case.value;
    needle =
      if case ? reason
      then "${lib.showOption case.path} is set but ${mode} does not deliver it to ${case.runtime} (reason: ${case.reason})"
      else lib.showOption case.path + (case.suffix or "");
    present =
      if case ? reason
      then builtins.elem needle
      else contains needle;
    enabled = harness.setEnable case.runtime true;
    messages = evaluate mode (lib.recursiveUpdate enabled input);
  in
    present messages
    && (!(case ? count) || builtins.length messages == case.count)
    && !present emptyCaseWarnings.${mode}.${case.runtime}
    && evaluate mode input == [];
  kiroManualPrioritySilent = lib.all (config: evaluate "devenv" config == []) [
    {
      ai = {
        kiro.cli.enable = true;
        rules.probe = {
          inclusion = ["always" "manual"];
          text = "root";
        };
      };
    }
    {
      ai = {
        kiro = {
          cli.enable = true;
          rules.probe = {
            inclusion = "always";
            text = "native";
          };
        };
        rules.probe = {
          inclusion = ["manual"];
          text = "root";
        };
      };
    }
  ];
  # config/ai-delivery-facts.nix is pure `{lib}` data, so it lists the
  # runtimes with a native agent layer by name. The record is the source of
  # truth: `native.agents` must be an agents row's input exactly when the
  # runtime's record has `agentNativeType`.
  nativeAgentsListed = lib.all (row:
    builtins.elem ["ai" row.ecosystem "native" "agents"] (row.inputOptions or [])
    == (records.${row.ecosystem} ? agentNativeType))
  (lib.filter (row: row.surface == "agents") policy.rows);
  mcp = import ../../lib/mcp.nix {inherit lib;};
  # `isDarwin` is forced in BOTH directions rather than left to the host: this
  # check runs on x86_64-linux and aarch64-darwin, so reading the real platform
  # would make the non-Darwin arms assert nothing on the Darwin runner.
  trustWarnings = {
    backend,
    darwin ? false,
    trustedMcpTools ? ["@probe"],
    v3 ? false,
  }: let
    declaration = {
      ai.kiro = {
        cli.enable = true;
        cli = {inherit trustedMcpTools v3;};
      };
    };
  in
    import ../../lib/ai/delivery-warnings.nix {inherit lib;} {
      appRecord = records.kiro // {pkgs.stdenv.hostPlatform.isDarwin = darwin;};
      inherit backend;
      inherit
        (
          if backend == "hm"
          then harness.evalHm declaration
          else harness.evalDevenv declaration
        )
        config
        ;
    };
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-darwin-trust = harness.mkTest "ai-warnings-darwin-trust" (
      # Withheld: Darwin under either engine, and the v3 `acp` arm anywhere.
      contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
        backend = "hm";
        darwin = true;
      })
      && contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        darwin = true;
        v3 = true;
      })
      && contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        v3 = true;
      })
      # Recovered, or never withheld.
      && trustWarnings {
        backend = "hm";
        darwin = true;
        v3 = true;
      }
      == []
      && trustWarnings {
        backend = "hm";
        darwin = true;
        trustedMcpTools = [];
      }
      == []
      && trustWarnings {backend = "devenv";} == []
      && trustWarnings {backend = "hm";} == []
    );
    ai-warnings-delivery = harness.mkTest "ai-warnings-delivery" (
      lib.all (row: assert lib.assertMsg (rowCase row) "warning row ${policy.key row}"; true) gaps
      && lib.all (case: assert lib.assertMsg (casePass case) "warning case ${lib.concatStringsSep "." case.path}"; true) cases
      && lib.all (case: assert lib.assertMsg (casePass case) "warning gap ${case.runtime}/${case.mode}/${lib.showOption case.path}"; true) gapCases
      && lib.assertMsg consumedRootsQuiet "consumed shared surfaces must not warn"
      && lib.assertMsg kiroManualPrioritySilent "Kiro manual warnings follow the selected trigger and native replacement"
      && lib.assertMsg effortSilent "delivered or withheld reasoning effort must not warn"
      && lib.assertMsg deliveredLspSilent "an LSP cell warns about `extensions`, or warns with no gap recorded for it"
      && lib.assertMsg nativeAgentsListed "config/ai-delivery-facts.nix must list `ai.<runtime>.native.agents` as an agents input exactly for the runtimes whose record has `agentNativeType`"
    );
    ai-warnings-delivery-input-options = harness.mkTest "ai-warnings-delivery-input-options" inputsDeclared;
    ai-warnings-kiro-hook-prompts = harness.mkTest "ai-warnings-kiro-hook-prompts" (
      lib.all (mode: let
        warningsFor = extra:
          evaluate mode {
            ai.kiro = {
              cli.enable = true;
              hooks.probe =
                lib.recursiveUpdate {
                  trigger = "UserPromptSubmit";
                  action.command = "true";
                }
                extra;
            };
          };
        unset = warningsFor {};
        withPrompt = warningsFor {action.prompt.text = "probe";};
      in
        assert lib.assertMsg (unset == []) "${mode}: command hook with no prompt warned: ${builtins.toJSON unset}";
          contains "ai.kiro.hooks.probe.action.prompt" withPrompt)
      ["devenv" "hm"]
    );
    ai-warnings-mcp-assertions = harness.mkTest "ai-warnings-mcp-assertions" (
      let
        valid = mcp.evalSettings "gitlab-mcp" {
          assertions = [
            {
              assertion = true;
              message = "positive control";
            }
          ];
        };
        invalid = builtins.tryEval (mcp.evalSettings "gitlab-mcp" {
          assertions = [
            {
              assertion = false;
              message = "first settings failure";
            }
            {
              assertion = false;
              message = "second settings failure";
            }
          ];
        });
      in
        valid.instanceUrl == null && !(valid ? assertions) && !invalid.success
    );
    # A context or rule unit whose file is switched off (`content.enable =
    # false`) or replaced with the consumer's own bytes warns, naming the
    # unit, the file option that dropped it and a per-runtime way to withhold
    # it; the warning is what makes the drop visible. Withholding the unit or
    # having nothing to carry is quiet.
    ai-warnings-switched-off-files = harness.mkTest "ai-warnings-switched-off-files" (
      let
        offMessage = messages: unit: file: remedy:
          lib.any (message:
            lib.hasInfix "${unit} is set but" message
            && lib.hasInfix "${file}.content.enable = false switches off" message
            && lib.hasInfix remedy message)
          messages;
        # Codex's shared AGENTS.md on devenv, switched off by ANOTHER
        # runtime's public entry: the message names Kiro's option.
        sharedOff = evaluate "devenv" {
          ai = {
            codex.enable = true;
            context.text = "CTX";
            kiro = {
              cli.enable = true;
              files."AGENTS.md".content.enable = false;
            };
            rules.probe.text = "RULE";
          };
        };
        # Codex's user AGENTS.md on Home Manager.
        hmCodexOff = evaluate "hm" {
          ai = {
            codex = {
              enable = true;
              files.".codex/AGENTS.md".content.enable = false;
              rules.local.text = "LOCAL";
            };
            rules.probe.text = "RULE";
          };
        };
        # One scoped Kiro steering file on devenv; Claude rule file on HM.
        steeringOff = evaluate "devenv" {
          ai.kiro = {
            cli.enable = true;
            files.".kiro/steering/scoped.md".content.enable = false;
            rules.scoped = {
              matcher = ["src/**"];
              text = "SCOPED";
            };
          };
        };
        claudeOff = evaluate "hm" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".content.enable = false;
            };
            rules.probe.text = "RULE";
          };
        };
        # Quiet controls.
        withheld = evaluate "devenv" {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.enable = false;
              normalized.context = lib.mkForce null;
              rules.probe.enable = false;
            };
            context.text = "CTX";
            rules.probe.text = "RULE";
          };
        };
        # A whole-file replacement drops the units the generated file carried,
        # on the shared devenv AGENTS.md and on each backend's own files.
        replacedMessage = messages: unit: file: remedy:
          lib.any (message:
            lib.hasInfix "${unit} is set but" message
            && lib.hasInfix "${file}.content replaces" message
            && lib.hasInfix remedy message)
          messages;
        replaced = evaluate "devenv" {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.text = "MINE";
            };
            context.text = "CTX";
            rules.probe.text = "RULE";
          };
        };
        hmCodexReplaced = evaluate "hm" {
          ai = {
            codex = {
              enable = true;
              files.".codex/AGENTS.md".content.text = "MINE";
            };
            rules.probe.text = "RULE";
          };
        };
        claudeReplaced = evaluate "devenv" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".content.source = pkgs.writeText "mine" "MINE";
            };
            rules.probe.text = "RULE";
          };
        };
        # Changing how a generated file lands keeps its bytes: quiet.
        symlinked = evaluate "hm" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".method = "symlink";
            };
            rules.probe.text = "RULE";
          };
        };
        # Every runtime's ordinary generated files carry the `_generated`
        # marker: with nothing overridden, no unit reads as replaced.
        ordinary = mode:
          evaluate mode {
            ai = {
              claude.enable = true;
              codex.enable = true;
              context.text = "CTX";
              copilot.enable = true;
              kimchi.enable = true;
              kiro.cli.enable = true;
              rules = {
                probe.text = "RULE";
                scoped = {
                  matcher = ["src/**"];
                  text = "SCOPED";
                };
              };
            };
          };
        nothing = evaluate "devenv" {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content.enable = false;
          };
        };
        nothingReplaced = evaluate "devenv" {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content.text = "MINE";
          };
        };
      in
        offMessage sharedOff "ai.rules.probe" ''ai.kiro.files."AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && offMessage sharedOff "ai.context" ''ai.kiro.files."AGENTS.md"'' "ai.codex.normalized.context = lib.mkForce null"
        && offMessage sharedOff "ai.context" ''ai.kiro.files."AGENTS.md"'' "withhold it from kiro"
        && offMessage hmCodexOff "ai.rules.probe" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && offMessage hmCodexOff "ai.codex.rules.local" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.local.enable = false"
        && offMessage steeringOff "ai.kiro.rules.scoped" ''ai.kiro.files.".kiro/steering/scoped.md"'' "ai.kiro.rules.scoped.enable = false"
        && offMessage claudeOff "ai.rules.probe" ''ai.claude.files.".claude/rules/probe.md"'' "ai.claude.rules.probe.enable = false"
        && replacedMessage replaced "ai.rules.probe" ''ai.codex.files."AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && replacedMessage replaced "ai.context" ''ai.codex.files."AGENTS.md"'' "ai.codex.normalized.context = lib.mkForce null"
        && replacedMessage hmCodexReplaced "ai.rules.probe" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && replacedMessage claudeReplaced "ai.rules.probe" ''ai.claude.files.".claude/rules/probe.md"'' "ai.claude.rules.probe.enable = false"
        && !(contains "switches off" replaced)
        && !(contains "the file that carries it" withheld)
        && !(contains "the file that carries it" symlinked)
        && !(contains "the file that carries it" nothing)
        && !(contains "the file that carries it" (ordinary "hm"))
        && !(contains "the file that carries it" (ordinary "devenv"))
        && !(contains "the file that carries it" nothingReplaced)
    );

    ai-warnings-tombstones = harness.mkTest "ai-warnings-tombstones" (
      evaluate "hm" {
        ai.copilot = {
          enable = true;
          rules.probe.enable = false;
        };
        ai.rules.probe.text = "probe";
      }
      == []
      && evaluate "hm" {
        ai.kimchi.enable = true;
        ai.rules.probe.enable = false;
      }
      == []
      && evaluate "hm" {
        ai.copilot = {
          enable = true;
          context.text = "";
        };
      }
      == []
      && evaluate "devenv" {
        ai.claude = {
          enable = true;
          lspServers.probe = null;
        };
        ai.lspServers = sample.lspServers;
      }
      == []
    );
  };
}

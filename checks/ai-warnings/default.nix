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
  records = lib.mapAttrs (_: file:
    import file {
      lib = harness.hmLib;
      inherit pkgs;
    }) {
    claude = ../../packages/claude-code/lib/mkClaude.nix;
    codex = ../../packages/chatgpt-codex/lib/mkCodex.nix;
    copilot = ../../packages/copilot-cli/lib/mkCopilot.nix;
    kimchi = ../../packages/kimchi/lib/mkKimchi.nix;
    kiro = ../../packages/kiro-cli/lib/mkKiro.nix;
  };
  contains = needle: messages: lib.any (lib.hasInfix needle) messages;
  sample = {
    agents.probe = {
      description = "probe";
      instructions = "probe";
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
    supported = builtins.elem row.surface records.${row.ecosystem}.supportedPools;
    enabled = {ai.${row.ecosystem}.enable = true;};
    empty = evaluate row.mode enabled;
    messagesFor = path: evaluate row.mode (lib.recursiveUpdate enabled (lib.setAttrByPath path sample.${row.surface}));
    warns = path: let
      messages = messagesFor path;
      needle = lib.showOption path;
    in
      contains needle messages
      && contains (row.deliveryGap or row.reason) messages
      && !contains needle empty;
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
    # A bare root pool is deliberately silent unless the runtime can tombstone
    # it one name at a time: an excluded pool has no per-runtime option, and a
    # non-keyed pool (context, hooks) composes root with per-runtime, so the
    # warning would have no consumer remedy. The silence is the assertion. A
    # supported non-keyed pool must still warn for its PER-RUNTIME path, which
    # is also what proves this evaluation produces warnings at all.
    else if builtins.length path == 2 && !(supported && builtins.elem row.surface policy.keyedSurfaces)
    then
      messagesFor path
      == []
      && empty == []
      && (!supported || warns ["ai" row.ecosystem row.surface])
    else warns path;
  # `ai.kiro.trustedMcpTools` is NOT a case here: the wrapper appends
  # `--trust-tools` on both backends, so a devenv consumer setting it has no
  # delivery gap to be told about. The narrower withhold it does have — the v3
  # `acp` arm and Darwin's bundle-discovery launcher — is asserted by
  # ai-warnings-darwin-trust below.
  #
  # Root pools nothing per-runtime can withdraw (`ai.agents`/`ai.hooks` on
  # Kiro, `ai.shell` on Kimchi and Copilot, `ai.context` on Copilot's and
  # `ai.hooks` on Kimchi's Home Manager rows) are not cases either: they are
  # silent by design, and rowCase above asserts that silence.
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
      {
        runtime = "codex";
        path = ["ai" "agents" "probe"];
        value = sample.agents.probe // {tools = ["Read"];};
        suffix = ".tools";
      }
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
        else if surface == "outputStyles"
        then {probe = "probe";}
        else {probe = pkgs.emptyDirectory;};
    }) ["marketplaces" "outputStyles" "plugins" "unpinLaunchEffort"]
    ++ [
      {
        runtime = "claude";
        path = ["ai" "claude" "native" "settings" "mcpServers"];
        value.probe.command = "probe";
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
  # Effort stays silent wherever the factory closes the gap or the runtime has
  # no per-runtime remedy. Kimchi lowers losslessly on both backends, and
  # Copilot on Home Manager, whose user file every mode reads. Copilot on
  # devenv is silent once the consumer withholds the native value, which is
  # the remedy its warning names. Kiro persists effort only per model, so it
  # declares no normalized settings pool, and a bare root value for an
  # unsupported pool does not warn (packages/kiro-cli/checks:
  # kiro-settings-pool-excluded).
  effortSilent = lib.all ({
    runtime,
    modes,
    paths,
    extra ? {},
  }:
    lib.all (mode:
      lib.all (path: let
        enabled = lib.recursiveUpdate {ai.${runtime}.enable = true;} extra;
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
    {
      runtime = "kiro";
      modes = ["devenv" "hm"];
      paths = [["ai" "settings" "reasoningEffort"]];
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
        messages = evaluate mode (lib.recursiveUpdate {ai.${runtime}.enable = true;} (lib.setAttrByPath path {
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
  casePass = case: let
    mode = case.mode or "devenv";
    input = lib.setAttrByPath case.path case.value;
    needle = lib.showOption case.path + (case.suffix or "");
    enabled = {ai.${case.runtime}.enable = true;};
  in
    contains needle (evaluate mode (lib.recursiveUpdate enabled input))
    && !contains needle (evaluate mode enabled)
    && evaluate mode input == [];
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
        enable = true;
        inherit trustedMcpTools v3;
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
  # A hand-built config, not a harness eval: every policy path goes through
  # lib.attrByPath, which answers `null` for a shared pool a minimal
  # composition never declared, and the real module trees always declare them
  # all. Each branch of `present` has to read that null as "nothing requested"
  # instead of crashing the whole evaluation.
  undeclaredSharedPools = backend:
    import ../../lib/ai/delivery-warnings.nix {inherit lib;} {
      appRecord = records.copilot;
      inherit backend;
      config.ai.copilot.enable = true;
    };
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-darwin-trust = harness.mkTest "ai-warnings-darwin-trust" (
      # Withheld: Darwin under either engine, and the v3 `acp` arm anywhere.
      contains "ai.kiro.trustedMcpTools" (trustWarnings {
        backend = "hm";
        darwin = true;
      })
      && contains "ai.kiro.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        darwin = true;
        v3 = true;
      })
      && contains "ai.kiro.trustedMcpTools" (trustWarnings {
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
      && lib.assertMsg effortSilent "reasoning effort warns where the factory closes the gap or no per-runtime remedy exists"
      && lib.assertMsg deliveredLspSilent "an LSP cell warns about `extensions`, or warns with no gap recorded for it"
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
    # false`) warns, naming the unit, the file option that switched it off and
    # a per-runtime way to withhold it; the warning is what makes the drop
    # visible. Withholding the unit, replacing the file with other bytes, or
    # having nothing to carry are all quiet.
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
              enable = true;
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
            enable = true;
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
        nothing = evaluate "devenv" {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content.enable = false;
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
        && !(contains "switches off" withheld)
        && !(contains "switches off" replaced)
        && !(contains "switches off" nothing)
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
      && undeclaredSharedPools "hm" == []
      && undeclaredSharedPools "devenv" == []
    );
  };
}

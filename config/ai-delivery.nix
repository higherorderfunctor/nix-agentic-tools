# Delivery policy, not a second implementation of the writers. One row per
# surface/ecosystem/mode; additionalWriters records independent destinations or
# conditional strategies within that row. All imperative writers carry probes.
# Paths use default config directories. <name>/<leaf> denote consumer keys;
# writerAttr is an exact evaluated attribute path for a specimen named probe
# (skill leaf SKILL.md), never a dotted-string parser or a wildcard.
{lib}: let
  ecosystems = import ../lib/ai/runtimes.nix;
  modes = ["devenv" "hm"];
  surfaces = ["agents" "context" "environmentVariables" "hooks" "lspServers" "mcpServers" "permissions" "rules" "settings" "skills"];
  primitives = ["notApplicable" "ownLeaves" "ownPathDeclarative" "ownPathManaged" "ownWrapper" "upstream"];
  imperativePrimitives = ["ownLeaves" "ownPathManaged"];
  both = value: {
    devenv = value;
    hm = value;
  };
  source = package: "packages/${package}/lib/mk${{
      chatgpt-codex = "Codex";
      claude-code = "Claude";
      copilot-cli = "Copilot";
      kimchi = "Kimchi";
      kiro-cli = "Kiro";
    }.${
      package
    }}.nix";
  absent = reason: {
    inherit reason;
    primitive = "notApplicable";
    target = null;
    writerAttr = [];
    pruneTrigger = "none";
  };
  declarative = mode: path: {
    primitive = "ownPathDeclarative";
    target =
      (
        if mode == "hm"
        then "$HOME/"
        else "$DEVENV_ROOT/"
      )
      + path;
    writerAttr =
      (
        if mode == "hm"
        then ["home" "file"]
        else ["files"]
      )
      ++ [(lib.replaceStrings ["<name>" "<leaf>"] ["probe" "SKILL.md"] path)];
    pruneTrigger =
      if mode == "hm"
      then "Home Manager generation diff on switch; changed declarations replace the store symlink."
      else "devenv:files:cleanup on SHELL ENTRY ONLY removes retired store symlinks; retained entries are regenerated. Real files are not pruned.";
  };
  paths = hm: devenv: {
    devenv = declarative "devenv" devenv;
    hm = declarative "hm" hm;
  };
  delegated = mode: attr: target: {
    inherit target;
    primitive = "upstream";
    writerAttr =
      (
        if mode == "hm"
        then ["programs" "claude-code"]
        else ["claude" "code"]
      )
      ++ [attr];
    pruneTrigger =
      if mode == "hm"
      then "Upstream Home Manager projection, then generation diff on switch."
      else "Upstream devenv files projection, then files:cleanup on SHELL ENTRY ONLY.";
    reason = "This factory hands ${attr} to the consumer's upstream Claude module; its implementation and pin are outside this policy.";
    reverifyCommand =
      if mode == "hm"
      then ''rg -n 'home.file|settings|personalPlugin|mcpServers|lspServers|agents|skills|hooks' "$HM_SOURCE/modules/programs/claude-code/default.nix"; home-manager build --flake "$CONSUMER_FLAKE"''
      else ''rg -n 'files|mcpServers|mcpContent' "$(nix eval --raw --expr '(builtins.getFlake (toString ./.)).inputs.devenv.outPath')/src/modules/integrations/claude.nix"'';
  };
  probe = option: nonEmpty: empty: {
    base = {};
    inherit option;
    nonEmpty = lib.setAttrByPath option nonEmpty;
    empty = lib.setAttrByPath option empty;
  };
  # An exempted writer's failures are RECORDED, not fatal. The gate errors the
  # moment an exempted writer survives BOTH arms ("exemption is stale"), so
  # every exemption below is a countdown the ownership fix has to spend.
  exempt = evidence: reason: {exemption = {inherit evidence reason;};};
  # Three HM settings merges share one defect and one shape, so they share one
  # reason; only the citation differs.
  gatedSettingsMerge = evidence:
    exempt evidence "Activation entry sits inside mkIf on a non-empty settings set, so an emptied declaration never merges the removal away.";
  leaves = activation: target: declaration: {
    inherit target;
    inputOptions = [(lib.concatStringsSep "." declaration.option)];
    primitive = "ownLeaves";
    writerAttr = ["home" "activation" activation];
    pruneTrigger = "On activation, hm-helpers/reconcile-toml.py retracts prior manifest-owned leaves, preserving unowned siblings.";
    probe = declaration;
  };
  wrapper = mode: executable: {
    primitive = "ownWrapper";
    target = "${executable} process environment (store launcher)";
    writerAttr =
      if mode == "hm"
      then ["home" "packages"]
      else ["packages"];
    pruneTrigger = "none; switching the profile/shell selects a new store launcher with the current environment.";
  };
  env = executable: lib.genAttrs modes (mode: wrapper mode executable);
  mcpProbe = ecosystem: probe ["ai" ecosystem "mcpServers"] {probe.command = "true";} {};
  settingsProbe = ecosystem: probe ["ai" ecosystem "nativeSettings"] {model = "probe";} {};
  hookProbe = probe ["ai" "kiro" "hooksJson"] {probe = ''{"event":"pre-commit"}'';} {};
  kiroManaged = mode: name: target: declaration: {
    inherit target;
    primitive = "ownPathManaged";
    writerAttr =
      if mode == "hm"
      then ["home" "activation" name]
      else ["tasks" name];
    pruneTrigger = "lib/ai/materialize.nix manifest prune at ${
      if mode == "hm"
      then "activation"
      else "shell entry"
    }; only previously owned paths are retired.";
    probe = declaration;
  };
  kiroMcp = mode: let
    primary =
      kiroManaged mode (
        if mode == "hm"
        then "kiroMcpJson"
        else "ai:kiro:materialize-mcp"
      )
      "${
        if mode == "hm"
        then "$HOME"
        else "$DEVENV_ROOT"
      }/.kiro/settings/mcp.json"
      ((mcpProbe "kiro") // {base.ai.kiro.mcpWriteMode = "overwrite";})
      // (
        if mode == "hm"
        then
          exempt "packages/kiro-cli/lib/mkKiro.nix:1784"
          "Writer sits inside mkIf on a non-empty merged pool, so an emptied declaration never prunes mcp.json."
        else
          exempt "packages/kiro-cli/lib/mkKiro.nix:1983"
          "This task does not exist: the devenv write is an enterShell fragment gated on a non-empty merged pool, so neither declaration reaches a task."
      );
    merge =
      primary
      // {
        primitive = "ownLeaves";
        condition = ''ai.kiro.mcpWriteMode = "merge"'';
        probe = (mcpProbe "kiro") // {base.ai.kiro.mcpWriteMode = "merge";};
        pruneTrigger = "On ${
          if mode == "hm"
          then "activation"
          else "shell entry"
        }, retire whole-path ownership preserving the file, then reconcile JSON leaves. First handover cannot identify historical unowned leaves.";
      };
  in
    primary
    // {
      condition = ''ai.kiro.mcpWriteMode = "overwrite" (default)'';
      additionalWriters =
        [merge]
        ++ lib.optional (mode == "hm") (primary
          // {
            writerAttr = ["home" "activation" "materialize-kiro-settings-prune"];
            role = "Retire merge leaves and prune retired whole paths before the write phase.";
          }
          // exempt "packages/kiro-cli/lib/mkKiro.nix:1786 (mkMcpJsonScript, where hooks use materializeLib.mkHmActivation at :1831)"
          "mcp.json is assembled by the bespoke mkMcpJsonScript instead of the materializer, so no .kiro/settings prune entry is emitted under either declaration.");
    };
  kiroHooks = mode: let
    primary =
      kiroManaged mode (
        if mode == "hm"
        then "materialize-kiro-hooks-write"
        else "ai:kiro:materialize-hooks"
      )
      "${
        if mode == "hm"
        then "$HOME"
        else "$DEVENV_ROOT"
      }/.kiro/hooks/<name>.json"
      hookProbe;
  in
    primary
    // {
      additionalWriters = lib.optional (mode == "hm") (primary
        // {
          writerAttr = ["home" "activation" "materialize-kiro-hooks-prune"];
          role = "Prune phase must survive an empty declaration as well as the write phase.";
        });
    };
  codexConfig = leaves "codexSettingsReconcile" "$HOME/.codex/config.toml" (settingsProbe "codex");
  copilotInert = "Factory documents this project file as undelivered: Copilot offers no flag or discovery for it. Presence is not proof of application consumption.";

  # A row's primary writer and additionalWriters use the same schema. Keeping
  # these together preserves the 10 x 5 x 2 matrix without hiding mixed ownership
  # (Claude settings, Kimchi's two documents, Kiro's two MCP strategies).
  definitions = {
    agents = {
      claude = {
        devenv = absent "Parity gap: mergedAgents is not consumed by mkClaude.devenv.config, although the option exists.";
        hm = delegated "hm" "agents" "$HOME/.claude/agents/<name>.md";
      };
      codex = paths ".codex/agents/<name>.toml" ".codex/agents/<name>.toml";
      copilot = paths ".copilot/agents/<name>.md" ".github/agents/<name>.agent.md";
      kimchi = both (absent "Kimchi's supportedPools excludes agents and no native agent writer exists.");
      kiro = paths ".kiro/agents/<name>.json" ".kiro/agents/<name>.json";
    };
    context = {
      claude = paths ".claude/CLAUDE.md" ".claude/CLAUDE.md";
      codex = paths ".codex/AGENTS.md" "AGENTS.md";
      copilot = {
        devenv = declarative "devenv" ".github/copilot-instructions.md";
        hm = absent "Home Manager context is deliberately inert: the .github context surface is project-scoped.";
      };
      kimchi = paths ".config/kimchi/harness/AGENTS.md" ".config/kimchi/harness/AGENTS.md";
      kiro = lib.genAttrs modes (mode:
        (declarative mode (
          if mode == "hm"
          then ".kiro/steering/AGENTS.md"
          else "AGENTS.md"
        ))
        // {
          additionalWriters = [
            ((kiroManaged mode
                (
                  if mode == "hm"
                  then "retire-materialize-kiro-steering"
                  else "ai:kiro:retire-steering-copies"
                )
                "${
                  if mode == "hm"
                  then "$HOME"
                  else "$DEVENV_ROOT"
                }/.kiro/steering/<legacy-owned-file>"
                (probe ["ai" "kiro" "context"] {text = "probe";} {}))
              // {
                role = "Enable-independent legacy-copy retirement; current context and rules use declarative paths.";
              })
          ];
        });
    };
    environmentVariables = {
      claude = both (absent "Claude excludes the environmentVariables pool; nativeSettings.env is delivered through settings instead.");
      codex = env "codex";
      copilot = env "copilot";
      kimchi = env "kimchi";
      kiro = env "kiro-cli";
    };
    hooks = {
      claude = {
        hm =
          (delegated "hm" "settings" "$HOME/.claude/settings.json (hooks)")
          // {
            additionalWriters = [(delegated "hm" "hooks" "$HOME/.claude/hooks/<name>")];
          };
        devenv =
          (declarative "devenv" ".claude/settings.json")
          // {
            additionalWriters = [(declarative "devenv" ".claude/hooks/<name>")];
          };
      };
      codex = paths ".codex/hooks.json" ".codex/hooks.json";
      copilot = both (absent "Copilot's supportedPools excludes hooks and no native hook writer exists.");
      kimchi = both (absent "Kimchi's supportedPools excludes hooks; harnessSettings resource toggles are settings, not hook definitions.");
      kiro = lib.genAttrs modes kiroHooks;
    };
    lspServers = {
      claude = {
        devenv = absent "Parity gap: Claude devenv exists but never consumes mergedLspServers or writes LSP configuration.";
        hm = delegated "hm" "lspServers" "$HOME/.claude/skills/claude-code-home-manager/.lsp.json";
      };
      codex = both (absent "Codex's supportedPools excludes lspServers.");
      copilot =
        (paths ".copilot/lsp-config.json" ".config/github-copilot/lsp-config.json")
        // {
          devenv = (declarative "devenv" ".config/github-copilot/lsp-config.json") // {deliveryGap = copilotInert;};
        };
      kimchi = both (absent "Kimchi's supportedPools excludes lspServers.");
      kiro = paths ".kiro/settings/lsp.json" ".kiro/settings/lsp.json";
    };
    mcpServers = {
      claude = {
        devenv = delegated "devenv" "mcpServers" "$DEVENV_ROOT/.mcp.json";
        hm = delegated "hm" "mcpServers" "$HOME/.claude/skills/claude-code-home-manager/.mcp.json";
      };
      codex = {
        devenv = declarative "devenv" ".codex/config.toml";
        hm = codexConfig // {probe = mcpProbe "codex";};
      };
      copilot = paths ".copilot/mcp-config.json" ".config/github-copilot/mcp-config.json";
      kimchi = paths ".config/kimchi/harness/mcp.json" ".config/kimchi/harness/mcp.json";
      kiro = lib.genAttrs modes kiroMcp;
    };
    permissions = {
      claude = {
        devenv = declarative "devenv" ".claude/settings.json";
        hm = delegated "hm" "settings" "$HOME/.claude/settings.json (permissions)";
      };
      codex = {
        devenv = declarative "devenv" ".codex/config.toml";
        hm = codexConfig // {probe = probe ["ai" "codex" "nativeSettings" "permissions"] {probe.network.enabled = false;} {};};
      };
      copilot = both (absent "No permissions option or translation exists; arbitrary nativeSettings keys do not establish a permissions contract.");
      kimchi = both (absent "No permissions option or translation exists.");
      kiro = {
        devenv = absent "Parity gap: permissions/trustedMcpTools options exist, but mkKiro.devenv.config emits no permissions.yaml. Agent-local permission records remain part of agents.";
        hm = declarative "hm" ".kiro/settings/permissions.yaml";
      };
    };
    rules = {
      claude = paths ".claude/rules/<name>.md" ".claude/rules/<name>.md";
      codex = lib.genAttrs modes (mode:
        (declarative mode (
          if mode == "hm"
          then ".codex/AGENTS.md"
          else "AGENTS.md"
        ))
        // {
          additionalWriters = [
            ((declarative mode ".codex/rules/<name>.rules")
              // {
                inputOptions = ["ai.codex.execpolicyRules"];
                role = "Native execution-policy rules are a separate declaration from Markdown ai.rules.";
              })
          ];
        });
      copilot = {
        devenv = declarative "devenv" ".github/instructions/<name>.instructions.md";
        hm = absent "Home Manager rules are deliberately inert; the agents pool is a separate surface, not a rules fallback.";
      };
      kimchi = both (absent "Kimchi's supportedPools excludes rules.");
      kiro = {
        hm = declarative "hm" ".kiro/steering/<name>.md";
        devenv =
          (declarative "devenv" "AGENTS.md")
          // {
            condition = "Always-on unscoped rules join sharedAgentsMd; scoped/manual rules stay in steering.";
            additionalWriters = [(declarative "devenv" ".kiro/steering/<name>.md")];
          };
      };
    };
    settings = {
      claude = {
        hm =
          (delegated "hm" "settings" "$HOME/.claude/settings.json")
          // {
            additionalWriters = [
              (leaves "claudeUnpinLaunchEffort" "$HOME/.claude.json"
                (probe ["ai" "claude" "unpinLaunchEffort"] {probe = true;} {}))
            ];
          };
        devenv =
          (declarative "devenv" ".claude/settings.json")
          // {
            additionalWriters = [
              ((absent "unpinLaunchEffort is an explicit HM-only global ~/.claude.json operation; devenv does not mutate HOME.")
                // {
                  inputOptions = ["ai.claude.unpinLaunchEffort"];
                  warnOnlyExplicit = true;
                })
            ];
          };
      };
      codex = {
        devenv = declarative "devenv" ".codex/config.toml";
        hm = codexConfig;
      };
      copilot = {
        devenv = (declarative "devenv" ".config/github-copilot/settings.json") // {deliveryGap = copilotInert;};
        hm =
          leaves "copilotSettingsMerge" "$HOME/.copilot/settings.json" (settingsProbe "copilot")
          // gatedSettingsMerge "packages/copilot-cli/lib/mkCopilot.nix:293";
      };
      kimchi = {
        hm =
          (leaves "kimchiConfigMerge" "$HOME/.config/kimchi/config.json"
            (probe ["ai" "kimchi" "nativeSettings"] {
              llmEndpoint = "https://example.invalid";
              skillPaths = ["probe"];
            } {skillPaths = [];}))
          // {
            additionalWriters = [
              (leaves "kimchiHarnessSettingsMerge" "$HOME/.config/kimchi/harness/settings.json"
                (probe ["ai" "kimchi" "harnessSettings"] {resources.probe = true;} {})
                // gatedSettingsMerge "packages/kimchi/lib/mkKimchi.nix:258")
            ];
          };
        devenv =
          (declarative "devenv" ".config/kimchi/config.json")
          // {
            additionalWriters = [(declarative "devenv" ".config/kimchi/harness/settings.json")];
          };
      };
      kiro = {
        hm =
          leaves "kiroSettingsMerge" "$HOME/.kiro/settings/cli.json"
          (probe ["ai" "kiro" "nativeSettings"] {chat.defaultModel = "probe";} {})
          // gatedSettingsMerge "packages/kiro-cli/lib/mkKiro.nix:1864";
        devenv =
          (declarative "devenv" ".kiro/settings/cli.json")
          // {
            deliveryConstraint = "Only the pinned workspace-allowlisted setting keys are accepted; global-only settings fail module assertions.";
          };
      };
    };
    skills = {
      claude = {
        devenv = declarative "devenv" ".claude/skills/<name>/<leaf>";
        hm = delegated "hm" "skills" "$HOME/.claude/skills/<name>/<leaf>";
      };
      codex = paths ".agents/skills/<name>" ".agents/skills/<name>";
      copilot = paths ".copilot/skills/<name>" ".github/skills/<name>/<leaf>";
      kimchi = paths ".config/kimchi/harness/skills/<name>" ".config/kimchi/harness/skills/<name>/<leaf>";
      kiro = paths ".kiro/skills/<name>" ".kiro/skills/<name>/<leaf>";
    };
  };
  packages = {
    claude = "claude-code";
    codex = "chatgpt-codex";
    copilot = "copilot-cli";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  inputOptions = surface: ecosystem:
    if surface == "permissions"
    then
      if ecosystem == "kiro"
      then ["ai.kiro.permissions" "ai.kiro.trustedMcpTools"]
      else if builtins.elem ecosystem ["claude" "codex"]
      then ["ai.${ecosystem}.nativeSettings.permissions"]
      else []
    else if surface == "settings"
    then ["ai.${ecosystem}.nativeSettings"] ++ lib.optional (ecosystem == "kimchi") "ai.kimchi.harnessSettings"
    else if ecosystem == "kiro" && builtins.elem surface ["agents" "hooks"]
    then ["ai.kiro.${surface}" "ai.kiro.${surface}Dir"] ++ lib.optional (surface == "hooks") "ai.kiro.hooksJson"
    else ["ai.${surface}" "ai.${ecosystem}.${surface}"];
  flatten = declarations:
    lib.concatMap (surface:
      lib.concatMap (ecosystem:
        lib.mapAttrsToList (mode: writer:
          writer
          // lib.optionalAttrs (ecosystem == "kimchi" && mode == "devenv" && builtins.elem surface ["context" "mcpServers" "settings" "skills"]) {
            deliveryGap = "Kimchi reads its HOME config directory; these project-local files have no discovery or additive launcher flag.";
          }
          // {
            inherit ecosystem mode surface;
            evidence = source packages.${ecosystem};
            # Gaps need their inputs too: the warning engine must distinguish
            # an unused capability from a consumer request we cannot deliver.
            inputOptions = inputOptions surface ecosystem;
          })
        declarations.${surface}.${ecosystem}) (builtins.attrNames declarations.${surface})) (builtins.attrNames declarations);
  key = row: "${row.surface}/${row.ecosystem}/${row.mode}";
  writersOf = row: [row] ++ lib.concatMap (writer: writersOf (writer // {inherit (row) ecosystem mode surface;})) (row.additionalWriters or []);
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  validWriter = writer:
    lib.all (field: builtins.hasAttr field writer) ["primitive" "pruneTrigger" "target" "writerAttr"]
    && builtins.elem writer.primitive primitives
    && nonBlank writer.pruneTrigger
    && builtins.isList writer.writerAttr
    && lib.all nonBlank writer.writerAttr
    && (
      if writer.primitive == "notApplicable"
      then writer.target == null && writer.writerAttr == []
      else nonBlank writer.target && writer.writerAttr != []
    )
    && (!(builtins.elem writer.primitive ["notApplicable" "upstream"]) || nonBlank (writer.reason or ""))
    && (writer.primitive != "upstream" || nonBlank (writer.reverifyCommand or ""))
    && (!(builtins.elem writer.primitive imperativePrimitives)
      || (
        writer ? probe
        && lib.all (field: builtins.hasAttr field writer.probe) ["base" "empty" "nonEmpty" "option"]
        && writer.probe.option != []
        && writer.probe.nonEmpty != writer.probe.empty
      ))
    && (!(writer ? exemption) || (nonBlank (writer.exemption.reason or "") && nonBlank (writer.exemption.evidence or "")));
  expectedKeys = lib.concatMap (surface: lib.concatMap (ecosystem: map (mode: "${surface}/${ecosystem}/${mode}") modes) ecosystems) surfaces;
  validateRows = rows:
    assert lib.assertMsg (lib.all (row: lib.all (field: builtins.hasAttr field row) ["ecosystem" "mode" "surface"]) rows) "ai-delivery: every row must declare surface, ecosystem, and mode";
    assert lib.assertMsg (lib.all (row: lib.all validWriter (writersOf row)) rows) "ai-delivery: incomplete or invalid writer (required fields, primitive, reason, reverifyCommand, probe, or exemption)";
    assert lib.assertMsg (lib.sort builtins.lessThan (map key rows) == lib.sort builtins.lessThan expectedKeys) "ai-delivery: expected exactly one row for every surface/ecosystem in BOTH hm and devenv (use notApplicable with a reason for gaps)"; rows;
  rows = validateRows (flatten definitions);
in
  builtins.seq rows {
    inherit definitions ecosystems imperativePrimitives key modes primitives rows surfaces validateRows writersOf;
    imperativeWriters = lib.filter (writer: builtins.elem writer.primitive imperativePrimitives) (lib.concatMap writersOf rows);
  }

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
  # NO row declares a defect record any more — not an `exemption`, not an
  # `absentWriter`, not a `constantGate`. All three mechanisms stay in the gate
  # and in its schema, because they are how the NEXT defect gets documented,
  # and each is verified in both directions: a record the gate can no longer
  # reproduce is itself an error. What retired them:
  #
  # - `exemption` (a writer that exists and behaves wrongly) — every writer it
  #   answered for now reaches its removal path under an emptied declaration.
  # - `absentWriter` (a writerAttr that resolves to nothing, which an exemption
  #   must never excuse because that shape is indistinguishable from a typo) —
  #   kiro's devenv mcp task and its HM settings-prune entry are both emitted
  #   now, so the gate reports the records themselves as stale.
  # - `constantGate` (survives the empty arm for a reason unrelated to
  #   removal) — claude's unpin flags and kimchi's config.json reconcile
  #   through `own`, so the empty-arm pass IS evidence of removal.
  #
  # Retraction MECHANISM, one string per mechanism rather than per writer.
  # There is exactly one: every ownLeaves writer runs the same program, so the
  # jq recursive merge that could not remove a dropped key has no rows left.
  ownRetraction = "On activation, lib/ai/own.nix's write entry runs lib/ai/own.py, which reads the leaves the prior generation's ledger recorded, removes the retired ones, reasserts the declared ones, and preserves unowned siblings. Both loops live in that program's `run`: every retraction across every target, then every assertion.";
  # The same program with the other container, for a target whose units are
  # whole files. The ledger records one sha256 per file it wrote, so a file the
  # declaration dropped is removed, a file edited since it was written is
  # backed up first, and a path this generation never wrote is never touched.
  ownFiles = at: "On ${at}, lib/ai/own.py removes every file the prior generation's ledger recorded and this one no longer declares, then rewrites the ledger; a file in the same directory that it never wrote is left alone. The arms are `DirContainer.remove` against that program's REMOVE_ARMS table, transcribed from the shell it replaced.";
  # HM reconciles on activation, devenv on shell entry. Both retraction
  # mechanisms name the moment, and nothing else in a row varies with it.
  retractionMoment = mode:
    if mode == "hm"
    then "activation"
    else "shell entry";
  leaves = pruneTrigger: activation: target: declaration: {
    inherit pruneTrigger target;
    inputOptions = [declaration.option];
    primitive = "ownLeaves";
    writerAttr = ["home" "activation" activation];
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
  settingsProbe = ecosystem: probe ["ai" ecosystem "native" "settings"] {model = "probe";} {};
  hookProbe = probe ["ai" "kiro" "hooksJson"] {probe = ''{"event":"pre-commit"}'';} {};
  kiroManaged = pruneTrigger: mode: name: target: declaration: {
    inherit pruneTrigger target;
    primitive = "ownPathManaged";
    writerAttr =
      if mode == "hm"
      then ["home" "activation" name]
      else ["tasks" name];
    probe = declaration;
  };
  kiroMcp = mode: let
    primary =
      kiroManaged (ownFiles (retractionMoment mode)) mode (
        if mode == "hm"
        then "kiroMcpJson"
        else "ai:kiro:materialize-mcp"
      )
      "${
        if mode == "hm"
        then "$HOME"
        else "$DEVENV_ROOT"
      }/.kiro/settings/mcp.json"
      ((mcpProbe "kiro") // {base.ai.kiro.mcpWriteMode = "overwrite";});
    merge =
      primary
      // {
        primitive = "ownLeaves";
        condition = ''ai.kiro.mcpWriteMode = "merge"'';
        probe = (mcpProbe "kiro") // {base.ai.kiro.mcpWriteMode = "merge";};
        pruneTrigger = "On ${retractionMoment mode}, lib/ai/own.py RELEASES the whole-file claim to the co-owning document target in the same plan — the file survives and its ledger is dropped — and then reconciles the declared leaves. A first handover cannot identify historical unowned leaves.";
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
          });
    };
  kiroHooks = mode: let
    primary =
      kiroManaged (ownFiles (retractionMoment mode)) mode (
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
  codexConfig = leaves ownRetraction "codexSettingsReconcile" "$HOME/.codex/config.toml" (settingsProbe "codex");
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
          additionalWriters = let
            retirement = name: role:
              (kiroManaged (ownFiles (retractionMoment mode)) mode name
                "${
                  if mode == "hm"
                  then "$HOME"
                  else "$DEVENV_ROOT"
                }/.kiro/steering/<legacy-owned-file>"
                (probe ["ai" "kiro" "context"] {text = "probe";} {}))
              // {
                inherit role;
                # NOT an exemption: the gate verifies this claim in BOTH
                # directions, so a body that DOES vary with the declaration is
                # an error here, exactly as a passing exempted writer is.
                declarationIndependent = "This writer removes what a PRIOR generation's ledger recorded. Its `own` target declares NO units, so its plan — and therefore the whole body, which is one command over two store paths — is the same under every declaration by construction.";
              };
          in
            if mode == "hm"
            then [
              # Home Manager needs the pair: deleting a real file must happen
              # before checkLinkTargets (`.kiro/steering` is exactly a
              # copy→symlink flip), and the write phase then unlinks the
              # ledger. Both are enable-independent, so both are rows.
              (retirement "retire-materialize-kiro-steering" "Enable-independent legacy-copy retirement, prune phase: remove the files a prior generation's ledger recorded, before link generation.")
              (retirement "retire-materialize-kiro-steering-ledger" "Enable-independent legacy-copy retirement, write phase: unlink the drained ledger so later generations are inert.")
            ]
            else [
              (retirement "ai:kiro:retire-steering-copies" "Enable-independent legacy-copy retirement; current context and rules use declarative paths.")
            ];
        });
    };
    environmentVariables = {
      claude = both (absent "Claude excludes the environmentVariables pool; native.settings.env is delivered through settings instead.");
      codex = env "codex";
      copilot = env "copilot";
      kimchi = env "kimchi";
      kiro = env "kiro-cli";
    };
    hooks = {
      claude = {
        devenv =
          (declarative "devenv" ".claude/settings.json")
          // {
            additionalWriters = [(declarative "devenv" ".claude/hooks/<name>")];
          };
        hm =
          (delegated "hm" "settings" "$HOME/.claude/settings.json (hooks)")
          // {
            additionalWriters = [(delegated "hm" "hooks" "$HOME/.claude/hooks/<name>")];
          };
      };
      codex = paths ".codex/hooks.json" ".codex/hooks.json";
      copilot = both (absent "Copilot's supportedPools excludes hooks and no native hook writer exists.");
      kimchi = both (absent "Kimchi's supportedPools excludes hooks; native.harnessSettings resource toggles are settings, not hook definitions.");
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
        hm = codexConfig // {probe = probe ["ai" "codex" "native" "settings" "permissions"] {probe.network.enabled = false;} {};};
      };
      copilot = both (absent "No permissions option or translation exists; arbitrary native.settings keys do not establish a permissions contract.");
      kimchi = both (absent "No permissions option or translation exists.");
      kiro = {
        # NOT a parity gap, and the label used to invite "closing" it: Kiro
        # never looks in a project .kiro/ for permissions, so a devenv writer
        # would emit a file the runtime cannot read.
        devenv = absent "Kiro reads permissions only from ~/.kiro/settings/ (global) or ~/.kiro/workspace-roots/<hash>/, never a project .kiro/, so a devenv-written permissions.yaml would never be read (packages/kiro-cli/lib/mkKiro.nix:1524-1528, the comment establishing those read paths above the permissions option). Agent-local permission records remain part of agents.";
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
                inputOptions = [["ai" "codex" "execpolicyRules"]];
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
        devenv =
          (declarative "devenv" "AGENTS.md")
          // {
            condition = "Always-on unscoped rules join sharedAgentsMd; scoped/manual rules stay in steering.";
            additionalWriters = [(declarative "devenv" ".kiro/steering/<name>.md")];
          };
        hm = declarative "hm" ".kiro/steering/<name>.md";
      };
    };
    settings = {
      claude = {
        devenv =
          (declarative "devenv" ".claude/settings.json")
          // {
            additionalWriters = [
              ((absent "unpinLaunchEffort is an explicit HM-only global ~/.claude.json operation; devenv does not mutate HOME.")
                // {
                  inputOptions = [["ai" "claude" "unpinLaunchEffort"]];
                  warnOnlyExplicit = true;
                })
            ];
          };
        hm =
          (delegated "hm" "settings" "$HOME/.claude/settings.json")
          // {
            additionalWriters = [
              (leaves ownRetraction "claudeUnpinLaunchEffort" "$HOME/.claude.json"
                (probe ["ai" "claude" "unpinLaunchEffort"] {probe = true;} {}))
            ];
          };
      };
      codex = {
        devenv = declarative "devenv" ".codex/config.toml";
        hm = codexConfig;
      };
      copilot = {
        devenv = (declarative "devenv" ".config/github-copilot/settings.json") // {deliveryGap = copilotInert;};
        hm = leaves ownRetraction "copilotSettingsMerge" "$HOME/.copilot/settings.json" (settingsProbe "copilot");
      };
      kimchi = {
        devenv =
          (declarative "devenv" ".config/kimchi/config.json")
          // {
            additionalWriters = [(declarative "devenv" ".config/kimchi/harness/settings.json")];
          };
        hm =
          (leaves ownRetraction "kimchiConfigMerge" "$HOME/.config/kimchi/config.json"
            (probe ["ai" "kimchi" "native" "settings"] {
              llmEndpoint = "https://example.invalid";
              skillPaths = ["probe"];
            } {}))
          // {
            additionalWriters = [
              (leaves ownRetraction "kimchiHarnessSettingsMerge" "$HOME/.config/kimchi/harness/settings.json"
                (probe ["ai" "kimchi" "native" "harnessSettings"] {resources.probe = true;} {}))
            ];
          };
      };
      kiro = {
        devenv =
          (declarative "devenv" ".kiro/settings/cli.json")
          // {
            deliveryConstraint = "Only the pinned workspace-allowlisted setting keys are accepted; global-only settings fail module assertions.";
          };
        hm =
          leaves ownRetraction "kiroSettingsMerge" "$HOME/.kiro/settings/cli.json"
          (probe ["ai" "kiro" "native" "settings"] {chat.defaultModel = "probe";} {});
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
  # Lists of attribute keys, never dotted strings: a consumer key may itself
  # contain a dot (a `foo.bar.md` rule lands at key `foo.bar`), and a path that
  # is re-split on "." loses that key. Renderers use lib.showOption.
  #
  # `ai.kiro.trustedMcpTools` is deliberately NOT here. The wrapper appends
  # `--trust-tools` on BOTH backends (packages/kiro-cli/lib/mkKiro.nix:1127
  # hands it to packages/kiro-cli/lib/wrapPackage.nix:256 for either install
  # path), so listing it under a notApplicable permissions row made every
  # default devenv consumer read a delivery gap that does not exist. The one
  # genuinely withheld sliver — the `acp` arm under the v3 engine, and Darwin's
  # bundle-discovery launcher — is a wrapper fact, reported by
  # lib/ai/delivery-warnings.nix rather than by this row.
  inputOptions = surface: ecosystem:
    if surface == "permissions"
    then
      if ecosystem == "kiro"
      then [["ai" "kiro" "permissions"]]
      else if builtins.elem ecosystem ["claude" "codex"]
      then [["ai" ecosystem "native" "settings" "permissions"]]
      else []
    else if surface == "settings"
    then [["ai" ecosystem "native" "settings"]] ++ lib.optional (ecosystem == "kimchi") ["ai" "kimchi" "native" "harnessSettings"]
    else if ecosystem == "kiro" && builtins.elem surface ["agents" "hooks"]
    then [["ai" "kiro" surface] ["ai" "kiro" "${surface}Dir"]] ++ lib.optional (surface == "hooks") ["ai" "kiro" "hooksJson"]
    else [["ai" surface] ["ai" ecosystem surface]];
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
    && lib.all (path: builtins.isList path && path != [] && lib.all nonBlank path) (writer.inputOptions or [])
    && (!(writer ? absentWriter) || (nonBlank (writer.absentWriter.reason or "") && nonBlank (writer.absentWriter.evidence or "")))
    && !(writer ? absentWriter && writer ? exemption)
    && (!(writer ? constantGate) || nonBlank writer.constantGate)
    && (!(writer ? declarationIndependent) || nonBlank writer.declarationIndependent)
    && (!(writer ? exemption) || (nonBlank (writer.exemption.reason or "") && nonBlank (writer.exemption.evidence or "")));
  expectedKeys = lib.concatMap (surface: lib.concatMap (ecosystem: map (mode: "${surface}/${ecosystem}/${mode}") modes) ecosystems) surfaces;
  validateRows = rows:
    assert lib.assertMsg (lib.all (row: lib.all (field: builtins.hasAttr field row) ["ecosystem" "mode" "surface"]) rows) "ai-delivery: every row must declare surface, ecosystem, and mode";
    assert lib.assertMsg (lib.all (row: lib.all validWriter (writersOf row)) rows) "ai-delivery: incomplete or invalid writer (required fields, primitive, reason, reverifyCommand, probe, inputOptions as key lists, absentWriter, constantGate, declarationIndependent, or exemption)";
    assert lib.assertMsg (lib.sort builtins.lessThan (map key rows) == lib.sort builtins.lessThan expectedKeys) "ai-delivery: expected exactly one row for every surface/ecosystem in BOTH hm and devenv (use notApplicable with a reason for gaps)"; rows;
  rows = validateRows (flatten definitions);
in
  builtins.seq rows {
    inherit definitions ecosystems imperativePrimitives key modes primitives rows surfaces validateRows writersOf;
    imperativeWriters = lib.filter (writer: builtins.elem writer.primitive imperativePrimitives) (lib.concatMap writersOf rows);
  }

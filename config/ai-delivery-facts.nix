# Consumer facts and independent input probes. Physical paths, methods and
# activation names belong to the generated delivery matrix.
{lib}: let
  absent = reason: {
    inherit reason;
    primitive = "notApplicable";
    target = null;
    writerAttr = [];
    pruneTrigger = "none";
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
  wrapper = mode: executable: {
    primitive = "ownWrapper";
    target = "${executable} process environment (store launcher)";
    writerAttr =
      if mode == "hm"
      then ["home" "packages"]
      else ["packages"];
    pruneTrigger = "none; switching the profile/shell selects a new store launcher with the current environment.";
  };
  mcpProbe = ecosystem: probe ["ai" ecosystem "mcpServers"] {probe.command = "true";} {};
  settingsProbe = ecosystem: probe ["ai" ecosystem "native" "settings"] {model = "probe";} {};
  hookProbe = probe ["ai" "kiro" "hooksJson"] {probe = ''{"event":"pre-commit"}'';} {};
  ownRetraction = mode: "On ${retractionMoment mode}, lib/ai/own.nix's write entry runs lib/ai/own.py, which reads the leaves the prior generation's ledger recorded, removes the retired ones, reasserts the declared ones, and preserves unowned siblings. Both loops live in that program's `run`: every retraction across every target, then every assertion.";
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
  inputOptions = surface: ecosystem:
    if surface == "permissions"
    then
      if builtins.elem ecosystem ["kimchi" "kiro"]
      then [["ai" ecosystem "permissions"]]
      else if builtins.elem ecosystem ["claude" "codex"]
      then [["ai" ecosystem "native" "settings" "permissions"]]
      else []
    else if surface == "settings"
    then [["ai" ecosystem "native" "settings"]] ++ lib.optional (ecosystem == "kimchi") ["ai" "kimchi" "native" "harnessSettings"]
    else if ecosystem == "kiro" && builtins.elem surface ["agents" "hooks"]
    then [["ai" "kiro" surface] ["ai" "kiro" "${surface}Dir"]] ++ lib.optional (surface == "hooks") ["ai" "kiro" "hooksJson"]
    else [["ai" surface] ["ai" ecosystem surface]];
  both = value: {
    devenv = value;
    hm = value;
  };
  handDefinitions = {
    agents = {
      claude = {hm = delegated "hm" "agents" "$HOME/.claude/agents/<name>.md";};
    };
    context = {
      copilot = {hm = absent "Home Manager context is deliberately inert: the .github context surface is project-scoped.";};
    };
    environmentVariables = {
      claude = both (absent "Claude excludes the environmentVariables pool; native.settings.env is delivered through settings instead.");
      codex = lib.genAttrs modes (mode: wrapper mode "codex");
      copilot = lib.genAttrs modes (mode: wrapper mode "copilot");
      kimchi = lib.genAttrs modes (mode: wrapper mode "kimchi");
      kiro = lib.genAttrs modes (mode: wrapper mode "kiro-cli");
    };
    hooks = {
      claude = {hm = (delegated "hm" "settings" "$HOME/.claude/settings.json (hooks)") // {additionalWriters = [(delegated "hm" "hooks" "$HOME/.claude/hooks/<name>")];};};
      copilot = both (absent "Copilot's supportedPools excludes hooks and no native hook writer exists.");
      # Kimchi's own lifecycle reader takes only a trusted project's
      # .kimchi/hooks.json and .kimchi/hooks.local.json; its user-scope routes
      # are not sinks Home Manager can own (the reason says why).
      kimchi = {hm = absent "Kimchi reads its own lifecycle hooks only from a trusted project's .kimchi/hooks.json (src/extensions/kimchi-hooks/definition.ts:25-37). It has two user-scope routes, and neither is a sink Home Manager can own. A configured pi package's hooks/hooks.json would make Home Manager own the `packages` list in harness/settings.json and clobber `kimchi install`. The opt-in Claude Code hook adapter (extensions.claude-code-hook-adapter, defaultEnabled false, src/resources/definitions.ts:75-80) reads ~/.claude/settings.json (src/extensions/claude-code-hook-adapter/definition.ts:25-28), so a shared hook Claude already receives also fires in Kimchi once a user enables it, with nothing written for Kimchi. The bash-hook directory filters the bash tool only and is not a lifecycle sink.";};
    };
    lspServers = {
      claude = {
        devenv = absent "Parity gap: Claude devenv exists but never consumes mergedLspServers or writes LSP configuration.";
        hm = delegated "hm" "lspServers" "$HOME/.claude/skills/claude-code-home-manager/.lsp.json";
      };
      codex = both (absent "Codex's supportedPools excludes lspServers.");
      kimchi = both (absent "Kimchi's supportedPools excludes lspServers.");
    };
    mcpServers = {
      claude = {
        devenv = delegated "devenv" "mcpServers" "$DEVENV_ROOT/.mcp.json";
        hm = delegated "hm" "mcpServers" "$HOME/.claude/skills/claude-code-home-manager/.mcp.json";
      };
    };
    permissions = {
      claude = {hm = delegated "hm" "settings" "$HOME/.claude/settings.json (permissions)";};
      copilot = both (absent "No permissions option or translation exists; arbitrary native.settings keys do not establish a permissions contract.");
      kiro = {devenv = absent "Kiro reads permissions only from ~/.kiro/settings/ (global) or ~/.kiro/workspace-roots/<hash>/, never a project .kiro/, so a devenv-written permissions.yaml would never be read (packages/kiro-cli/lib/mkKiro.nix:1524-1528, the comment establishing those read paths above the permissions option). Agent-local permission records remain part of agents.";};
    };
    rules = {
      copilot = {hm = absent "Home Manager rules are deliberately inert; the agents pool is a separate surface, not a rules fallback.";};
      kimchi = both (absent "Kimchi's supportedPools excludes rules.");
    };
    settings = {
      claude = {hm = delegated "hm" "settings" "$HOME/.claude/settings.json";};
    };
    skills = {
      claude = {hm = delegated "hm" "skills" "$HOME/.claude/skills/<name>/<leaf>";};
    };
  };
  hand = builtins.listToAttrs (lib.concatMap (surface:
    lib.concatMap (ecosystem:
      lib.mapAttrsToList (mode: value: lib.nameValuePair "${surface}/${ecosystem}/${mode}" value)
      handDefinitions.${surface}.${ecosystem}) (builtins.attrNames handDefinitions.${surface}))
  (builtins.attrNames handDefinitions));
  inherit (import ./ai-delivery-schema.nix {inherit lib;}) imperativePrimitives key modes;
  evidence = {
    claude = "packages/claude-code/lib/mkClaude.nix";
    codex = "packages/chatgpt-codex/lib/mkCodex.nix";
    copilot = "packages/copilot-cli/lib/mkCopilot.nix";
    kimchi = "packages/kimchi/lib/mkKimchi.nix";
    kiro = "packages/kiro-cli/lib/mkKiro.nix";
  };
  copilotInert = "Factory documents this project file as undelivered: Copilot offers no flag or discovery for it. Presence is not proof of application consumption.";
  metadata = row:
    {
      evidence = evidence.${row.ecosystem};
      inputOptions = inputOptions row.surface row.ecosystem;
    }
    // lib.optionalAttrs (row.ecosystem == "copilot" && row.mode == "devenv" && row.surface == "settings") {deliveryGap = copilotInert;}
    // lib.optionalAttrs (key row == "settings/kimchi/devenv") {
      deliveryConstraint = "User-scope-only harness setting keys fail module assertions; project-capable keys reconcile into the fixed project harness path.";
    }
    // lib.optionalAttrs (key row == "settings/kiro/devenv") {
      deliveryConstraint = "Only the pinned workspace-allowlisted setting keys are accepted; global-only settings fail module assertions.";
    }
    // lib.optionalAttrs (key row == "rules/kiro/devenv") {
      condition = "Always-on unscoped rules join sharedAgentsMd; scoped/manual rules stay in steering.";
    };
  mcpConditions = {
    merge = ''ai.kiro.mcpWriteMode = "merge"'';
    overwrite = ''ai.kiro.mcpWriteMode = "overwrite" (default)'';
  };
  probeFor = row:
    if row.surface == "agents" && row.ecosystem == "kimchi"
    then
      probe ["ai" "kimchi" "agents"] {
        probe = {
          description = "probe";
          instructions.text = "probe";
        };
      } {}
    else if row.surface == "context"
    then probe ["ai" "kiro" "context"] {text = "probe";} {}
    else if row.surface == "hooks"
    then hookProbe
    else if row.surface == "mcpServers"
    then
      (mcpProbe row.ecosystem)
      // lib.optionalAttrs (row.ecosystem == "kiro") {
        base.ai.kiro.mcpWriteMode =
          lib.findFirst (mode: mcpConditions.${mode} == row.condition)
          (throw "ai-delivery: Kiro MCP needs an independent strategy probe") (builtins.attrNames mcpConditions);
      }
    else if row.surface == "permissions"
    then
      if row.ecosystem == "kimchi"
      then probe ["ai" "kimchi" "permissions"] {allow = ["probe"];} {}
      else probe ["ai" "codex" "native" "settings" "permissions"] {probe.network.enabled = false;} {}
    else if row.surface == "rules" && row.ecosystem == "claude"
    then probe ["ai" "rules"] {probe.text = "probe";} {}
    else if row.ecosystem == "codex" && row.surface == "rules" && lib.hasInfix "/rules/" row.target
    then probe ["ai" "codex" "execpolicyRules"] {probe = "prefix_rule(pattern = [\"probe\"], decision = \"allow\")";} {}
    else if row.ecosystem == "claude"
    then probe ["ai" "claude" "unpinLaunchEffort"] {probe = true;} {}
    else if row.ecosystem == "kimchi"
    then
      if lib.hasSuffix "/harness/settings.json" row.target
      then
        probe ["ai" "kimchi" "native" "harnessSettings"]
        (
          # `resources` is user-scope-only, so devenv rejects it.
          if row.mode == "hm"
          then {resources.probe = true;}
          else {hideThinkingBlock = true;}
        ) {}
      else
        probe ["ai" "kimchi" "native" "settings"] {
          llmEndpoint = "https://example.invalid";
          skillPaths = ["probe"];
        } {}
    else if row.ecosystem == "kiro"
    then
      probe ["ai" "kiro" "native" "settings"]
      (
        if row.mode == "hm"
        then {chat.defaultModel = "probe";}
        else {chat.enableTangentMode = true;}
      ) {}
    else settingsProbe row.ecosystem;
  annotate = row: let
    imperative = builtins.elem row.primitive imperativePrimitives;
    declaration = probeFor row;
  in
    row
    // lib.optionalAttrs imperative {probe = declaration;}
    // lib.optionalAttrs (imperative && row.surface == "settings") {inputOptions = [declaration.option];}
    // lib.optionalAttrs (imperative && row.surface == "context") {
      declarationIndependent = "This writer removes what a PRIOR generation's ledger recorded. Its `own` target declares NO units, so its plan — and therefore the whole body, which is one command over two store paths — is the same under every declaration by construction.";
    }
    // lib.optionalAttrs (row.ecosystem == "codex" && row.surface == "rules" && lib.hasInfix "/rules/" row.target) {
      inputOptions = [["ai" "codex" "execpolicyRules"]];
      role = "Native execution-policy rules are a separate declaration from Markdown ai.rules.";
    };
  supplements = {
    "settings/claude/devenv" = [
      ((absent "unpinLaunchEffort is an explicit HM-only global ~/.claude.json operation; devenv does not mutate HOME.")
        // {
          inputOptions = [["ai" "claude" "unpinLaunchEffort"]];
          warnOnlyExplicit = true;
        })
    ];
  };
in {
  inherit annotate hand key mcpConditions metadata supplements;
  pruneTrigger = mode: primitive:
    if primitive == "ownLeaves"
    then ownRetraction mode
    else if primitive == "ownPathManaged"
    then ownFiles (retractionMoment mode)
    else if mode == "hm"
    then "Home Manager generation diff on switch; changed declarations replace the store symlink."
    else "devenv:files:cleanup on SHELL ENTRY ONLY removes retired store symlinks; retained entries are regenerated. Real files are not pruned.";
}

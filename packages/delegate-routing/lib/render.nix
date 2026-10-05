{
  lib,
  runtime,
  families,
  models,
  techniques,
  routing ? {},
  workflows ? {},
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  selection = import ./select-families.nix {inherit lib;};
  inherit (selection) automatic select;
  inherit (import ./vocabulary.nix) delegateKinds tiers;
  runtimes = automatic {inherit runtime extraRuntimes manualExternalDelegates;};
  extras = lib.tail runtimes;
  selected = target: select families models.${target};
  targets = family: builtins.filter (target: builtins.elem family (selected target)) runtimes;
  candidates = selection.candidates families models runtimes;
  entryRenderer = import ./render-entries.nix {inherit lib;};
  capabilities = import ./capabilities.nix {inherit lib;};
  shippedTechniques = import ./techniques.nix {
    claudeUsageScript = "claude-usage";
    codexUsageScript = "codex-usage";
  };
  modes = ["acp" "headless" "interactive"];
  contract = node: {
    command = node.command or null;
    inherit (node) kind pinsEffort pinsModel;
    modes = lib.sort builtins.lessThan node.modes;
  };
  isShipped = target: name: builtins.hasAttr name (shippedTechniques.${target} or {});
  matchesShipped = target: name: node:
    isShipped target name
    && contract node == contract shippedTechniques.${target}.${name};
  observation = target: name: node: mode:
    if isShipped target name && !matchesShipped target name node
    then null
    else capabilities.find target name mode;
  summary = target: name: node: capability: mode: let
    measured = observation target name node mode;
  in
    if measured == null
    then
      if matchesShipped target name node
      then "unknown"
      else "unknown (declared, not observed)"
    else let
      record = measured.capabilities.${capability};
    in
      record.result
      + lib.optionalString (measured.runtimeVersion == null) " (historical; version unknown)"
      + lib.optionalString (capability == "nestingDepth" && record.value != null) " (${toString record.value})";
  modeSummary = target: name: node: capability:
    lib.concatMapStringsSep "; " (mode: "${mode}: ${summary target name node capability mode}") modes;
  observationDetails = target: delegates:
    lib.concatStringsSep "\n\n" (lib.concatLists (lib.mapAttrsToList (name: node:
      lib.concatMap (mode: let
        measured = observation target name node mode;
      in
        lib.optional (measured != null) ''
          **${name} / ${mode} evidence:** ${capabilities.header measured}
          ${lib.concatMapStringsSep "; " (capability: let
            record = measured.capabilities.${capability};
          in "${capability}: ${record.result} — ${record.evidence}") ["available" "linkedWorktreeCommit" "nestingDepth" "pinsEffort" "pinsModel" "runsOwnSubagents"]}
          Requested controls: `${builtins.toJSON measured.requested}`. Observed controls: `${builtins.toJSON measured.observed}`.
          Context: ${measured.context}. Replay: ${lib.concatMapStringsSep "; " (step: "`${step}`") measured.replay}.
        '')
      modes)
    delegates));
  routingText = entryRenderer.routing false routing;
  workflowText = entryRenderer.workflows false workflows;
  cell = lib.replaceStrings ["|" "\n"] ["\\|" " "];
  row = cells: "| ${lib.concatMapStringsSep " | " cell cells} |";
  table = columns: rows:
    lib.concatStringsSep "\n" ([
        (row columns)
        (row (map (_: "---") columns))
      ]
      ++ map row rows);
  familyLabel = family: "${family.name} (${family.vendor}) `${family.match}`";
  tier = name: let
    members = builtins.filter (family: family.tier == name) candidates;
  in
    lib.optionalString (members != []) ''
      ### ${name}

      ${table ["Family" "Use for" "Avoid for" "Effort (delegate)" "Reach"] (map (family: [
          (familyLabel family)
          family.useFor
          family.avoidFor
          family.effort
          (lib.concatMapStringsSep "; " (target:
            if target == runtime
            then "native"
            else "via ${target} external") (targets family))
        ])
        members)}
    '';
  techniqueBlock = target: externalOnly: let
    nodes = lib.filterAttrs (_: node: node.enable) techniques.${target};
    delegates = lib.filterAttrs (_: node: builtins.elem node.kind delegateKinds) nodes;
    nativeDelegates = lib.filterAttrs (_: node: builtins.elem node.kind ["subagent" "workflow"]) delegates;
    rootAssessment = mode: let
      measured = lib.mapAttrsToList (name: node: observation target name node mode) nativeDelegates;
      results = map (value:
        if value == null
        then "unknown"
        else value.capabilities.available.result)
      measured;
      versionedSupport = lib.any (value:
        value
        != null
        && value.runtimeVersion != null
        && value.capabilities.available.result == "supported")
      measured;
    in
      if versionedSupport
      then "supported (native delegate available)"
      else if builtins.elem "supported" results
      then "supported in recorded context (current version/config unknown)"
      else if results != [] && builtins.all (result: result == "unsupported") results
      then "unsupported for the declared native tools"
      else "unknown";
    info = lib.filterAttrs (_: node: builtins.elem node.kind ["introspect" "usage"]) nodes;
    hasCommand = lib.any (node: node.command != null) (builtins.attrValues delegates);
    command = node: lib.optionalString (node.command != null) "`${node.command}`";
  in
    lib.optionalString (nodes != {}) ''
      ### ${target} techniques

      ${lib.optionalString (delegates != {}) (table
        (["Technique" "Kind" "Pins model (declared input control)" "Pins effort (declared input control)" "Declared modes" "Availability by mode" "Runs own subagents" "Nesting depth" "Linked worktree commit" "Effective model pin" "Effective effort pin" "Notes"] ++ lib.optional hasCommand "Command")
        (lib.mapAttrsToList (name: node:
          [
            "`${name}`"
            (node.kind + lib.optionalString (externalOnly && node.kind != "external") " (inside the external root)")
            (builtins.toJSON node.pinsModel)
            (builtins.toJSON node.pinsEffort)
            (lib.concatStringsSep "+" node.modes)
            (modeSummary target name node "available")
            (modeSummary target name node "runsOwnSubagents")
            (modeSummary target name node "nestingDepth")
            (modeSummary target name node "linkedWorktreeCommit")
            (modeSummary target name node "pinsModel")
            (modeSummary target name node "pinsEffort")
            node.notes
          ]
          ++ lib.optional hasCommand (command node))
        delegates))}

      ${lib.optionalString externalOnly ''
        **${target} runtime orchestrator-delegate assessment:** An external root can own delegates when its native child tools are available. The child tool's own nesting capability is a separate observation.

        ${table ["Mode" "Runtime can own delegates" "Native tools available inside the external root"] (map (mode: [
            mode
            (rootAssessment mode)
            (
              if nativeDelegates == {}
              then "unknown (no declared native delegate tools)"
              else lib.concatStringsSep "; " (lib.mapAttrsToList (name: node: "`${name}`: ${summary target name node "available" mode}") nativeDelegates)
            )
          ])
          modes)}
      ''}

      ${observationDetails target delegates}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: node: "**${name} (${node.kind}):** ${lib.concatStringsSep "; " (lib.filter (value: value != "") [(command node) node.notes])}") info)}
    '';
  manual = target: ''
    ### ${target}

    ${lib.concatMapStringsSep "\n" (family: "- ${familyLabel family}") (selected target)}

    ${techniqueBlock target true}
    Not a candidate for auto-selection; use only when the user names it.
  '';
in ''
  ## Routing

  ${routingText}

  ${lib.optionalString (workflowText != "") "## Common workflows\n\n${workflowText}"}

  ## delegate sizing

  Each row is a family: pick the id with the highest version that matches its pattern in the live model list, comparing version numbers segment by segment (6.1 > 6 > 5.6), and use the runtime's own spelling from the introspection step (Claude's interactive tools take the alias, e.g. `opus`).

  ${lib.concatMapStringsSep "\n" tier tiers}
  Use a technique only if it appears in your tool list; an external technique's command must be on PATH. Availability and delegate capabilities are recorded separately for ACP, headless and interactive modes. A missing observation is unknown, not unsupported. Declared modes describe the configured contract. Declared input controls describe the configured technique; effective pins describe observed behavior. Changed shipped techniques do not borrow recorded evidence: their command, kind, modes and pin controls must match the shipped declaration. Custom techniques use observations matching their runtime, technique and mode, within the recorded context; unmatched techniques are declared, not observed. Recorded results do not attest the current runtime installation. Any runtime version, client or configuration mismatch means current behavior is unknown until replayed. Runtime version, session context and replay steps below bound each observation; verify the tools present in this session.

  ${techniqueBlock runtime false}
  ${lib.concatMapStringsSep "\n" (target: techniqueBlock target true) extras}

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegates\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''

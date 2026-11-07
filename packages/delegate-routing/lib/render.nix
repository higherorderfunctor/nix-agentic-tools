{
  lib,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
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
  # The id a launch route names for one harness: the family's current example
  # id for that target, or — for a family with no example there, as package
  # families are by design — an instruction the reader resolves against the
  # live model list.
  launchId = family: target: let
    id = family.example.${target} or "";
  in
    if lib.trim id != ""
    then "`${id}`"
    else "the highest id matching `${family.match}`";
  poolSuffix = family: target: let
    pool = selection.poolFor family target;
  in
    lib.optionalString (pool != null) " (pool ${pool})";
  # One sized delegate per harness goes through the technique that pins both
  # model and effort; from another harness only an external command runs, so
  # in-harness tools drop out of external reaches.
  launchTechnique = target: externalOnly: let
    kindOrder = {
      external = 3;
      subagent = 1;
      workflow = 2;
    };
    eligible = lib.filterAttrs (_: node:
      node.enable
      && builtins.elem node.kind delegateKinds
      && node.pinsModel == true
      && node.pinsEffort == true
      && (!externalOnly || node.kind == "external"))
    techniques.${target};
  in
    builtins.sort
    (a: b: kindOrder.${techniques.${target}.${a}.kind} < kindOrder.${techniques.${target}.${b}.kind})
    (builtins.attrNames eligible);
  launch = family: target: let
    names = launchTechnique target (target != runtime);
  in
    # Refused where both delivery paths render it (the module and the public
    # mkSkill helper meet here): a reach must name a technique, and a route
    # composes that technique's model value spelling, so the technique a route
    # names — enabled, pinning model and effort, first in kind order — must
    # exist and carry one. Disabled and out-ranked techniques never compose a
    # route and are not refused.
    if names == []
    then
      throw "ai.programs.delegate-routing.runtimes.${target}.techniques: enable a technique that pins model and effort${
        if target != runtime
        then "; from another harness it must be an external technique, otherwise ${target} must not be reached"
        else ""
      }"
    else let
      name = builtins.head names;
      node = techniques.${target}.${name};
    in
      if lib.trim node.modelArg == ""
      then throw "ai.programs.delegate-routing.runtimes.${target}.techniques.${lib.strings.escapeNixIdentifier name}.modelArg: name the model value spelling for techniques that pin model and effort"
      else "`${name}` with ${node.modelArg} ${launchId family target}";
  reach = family: target:
    (
      if target == runtime
      then "${runtime}: "
      else "via ${target}: "
    )
    + launch family target
    + poolSuffix family target;
  poolsText = lib.optionalString (pools != {}) ''
    ## Pools

    ${table ["Name" "Reader" "Measure" "Description"] (lib.mapAttrsToList (name: declared: let
        # The public render and mkSkill helpers pass pool declarations
        # without the module's defaults, so default the optional fields here.
        pool =
          {
            description = "";
            usage = null;
            window = null;
          }
          // declared;
        # Assertions own invalid-reader diagnostics, even if delivery forces
        # rendering before it collects the module's assertions.
        command =
          if pool.usage == null
          then null
          else techniques.${pool.usage.runtime}.${pool.usage.technique}.command or null;
      in [
        name
        (
          if command == null
          then "none"
          else "`${command}`"
        )
        (
          if pool.usage != null
          then "measured"
          else if pool.window == null
          then "unknown"
          else "configured: ${toString pool.window.limit} ${pool.window.unit} per month, resets day ${toString pool.window.resetDay}; current use unknown"
        )
        pool.description
      ])
      pools)}

  '';
  tier = name: let
    members = builtins.filter (family: family.tier == name) candidates;
  in
    lib.optionalString (members != []) ''
      ### ${name}

      ${table ["Family" "Orchestration" "Use for" "Avoid for" "Effort (delegate)" "Launch"] (map (family: [
          (familyLabel family)
          (family.orchestration or "")
          family.useFor
          family.avoidFor
          family.effort
          (lib.concatMapStringsSep "; " (reach family) (targets family))
        ])
        members)}
    '';
  techniqueBlock = target: externalOnly: let
    nodes = lib.filterAttrs (_: node:
      node.enable
      && (!externalOnly || builtins.elem node.kind ["external" "introspect" "usage"]))
    techniques.${target};
    delegates = lib.filterAttrs (_: node: builtins.elem node.kind delegateKinds) nodes;
    info = lib.filterAttrs (_: node: builtins.elem node.kind ["introspect" "usage"]) nodes;
    hasCommand = lib.any (node: node.command != null) (builtins.attrValues delegates);
    command = node: lib.optionalString (node.command != null) "`${node.command}`";
  in
    lib.optionalString (nodes != {}) ''
      ### ${target} techniques

      ${lib.optionalString (delegates != {}) (table
        (["Technique" "Kind" "Pins model" "Pins effort" "Modes" "Runs own subagents" "Notes"] ++ lib.optional hasCommand "Command")
        (lib.mapAttrsToList (name: node:
          [
            "`${name}`"
            node.kind
            (builtins.toJSON node.pinsModel)
            (builtins.toJSON node.pinsEffort)
            (lib.concatStringsSep "+" node.modes)
            node.runsOwnSubagents
            node.notes
          ]
          ++ lib.optional hasCommand (command node))
        delegates))}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: node: "**${name} (${node.kind}):** ${lib.concatStringsSep "; " (lib.filter (value: value != "") [(command node) node.notes])}") info)}
    '';
  manual = target: ''
    ### ${target}

    ${lib.concatMapStringsSep "\n" (family: "- ${familyLabel family}: ${launch family target}${poolSuffix family target}") (selected target)}

    ${techniqueBlock target true}
    Not a candidate for auto-selection; use only when the user names it.
  '';
in ''
  ## Routing

  ${routingText}

  ${lib.optionalString (workflowText != "") "## Common workflows\n\n${workflowText}"}

  ## delegate sizing

  Each row is a family: pick the id with the highest version that matches its pattern in the live model list, comparing version numbers segment by segment (6.1 > 6 > 5.6), and use the runtime's own spelling from the introspection step (the Claude Agent tool takes the alias, e.g. `opus`). The Orchestration column names the default orchestrators and the families reserved for hard work. The Launch column names, per harness, the technique that pins both model and effort and the id spelling it takes; a concrete id there is the family's current pick, and "the highest id matching" instructs the resolution above.

  ${poolsText}${lib.concatMapStringsSep "\n" tier tiers}
  Use a technique only if it appears in your tool list; an external technique's command must be on PATH. The Modes column says where each tool usually appears; an agent cannot reliably tell which mode it is in, but it can see its tools.

  ${techniqueBlock runtime false}
  ${lib.concatMapStringsSep "\n" (target: techniqueBlock target true) extras}

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegates\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''

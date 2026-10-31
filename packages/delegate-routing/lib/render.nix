{
  lib,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
  resolvedAgentFiles ? null,
  routing ? {},
  skill,
  workflows ? {},
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  selection = import ./select-families.nix {inherit lib;};
  inherit (selection) automatic select;
  inherit (import ./vocabulary.nix) delegateKinds tiers;
  runtimes = automatic {inherit runtime extraRuntimes manualExternalDelegates;};
  extras = lib.tail runtimes;
  agentFiles = import ./agent-files.nix {inherit lib;};
  agentSet =
    if resolvedAgentFiles != null
    then resolvedAgentFiles
    else agentFiles.resolve agentFiles.facts.models (selected "claude");
  selected = target: select families models.${target};
  targets = family: builtins.filter (target: builtins.elem family (selected target)) runtimes;
  candidates = selection.candidates families models runtimes;
  opencodeGo = import ./opencode-go.nix {inherit lib;};
  goRendered = lib.any (family: family.vendor == opencodeGo.vendor) (candidates ++ lib.concatMap selected manualExternalDelegates);
  entryRenderer = import ./render-entries.nix {inherit lib;};
  routingText = entryRenderer.routing false routing;
  workflowText = entryRenderer.workflows false workflows;
  entrySort = import ./resolve-entries.nix {inherit lib;};
  # One pass: placeholders inside replacement text stay as written.
  fill = template: values: lib.replaceStrings (map (key: "{${key}}") (builtins.attrNames values)) (builtins.attrValues values) template;
  phrase = name: values: let
    declared = skill.phrases.${name} or (throw "delegate-routing.skill.phrases.${name}: missing");
  in
    if declared.enable
    then fill declared.text values
    else "";
  cell = lib.replaceStrings ["|" "\n"] ["\\|" " "];
  row = cells: "| ${lib.concatMapStringsSep " | " cell cells} |";
  # Header text, order and presence come from the skill's column entries; each
  # column key names the function that fills its cell from one item.
  table = scope: columns: cells: items: let
    shown = entrySort.sort "delegate-routing.skill.columns.${scope}" columns;
    cellFor = column: cells.${column.name} or (throw "delegate-routing.skill.columns.${scope}.${column.name}: unknown column");
    fillers = map cellFor shown;
  in
    lib.concatStringsSep "\n" ([
        (row (map (column: column.value.text) shown))
        (row (map (_: "---") shown))
      ]
      ++ map (item: row (map (filler: filler item) fillers)) items);
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
    else phrase "Model pattern" {inherit (family) match;};
  poolSuffix = family: target: let
    pool = selection.poolFor family target;
  in
    lib.optionalString (pool != null) (phrase "Pool binding" {inherit pool;});
  # Every enabled technique pinning both model and effort is eligible unless
  # its launchRoute is false, in kind order; from another harness only an
  # external command runs, so in-harness tools drop out of external reaches.
  launchTechnique = target: externalOnly: let
    kindOrder = {
      external = 3;
      subagent = 1;
      workflow = 2;
    };
    eligible = lib.filterAttrs (_: node:
      node.enable
      && node.launchRoute
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
    names = builtins.filter (name: name != "Agent with generated agent file" || agentSet ? ${family.name}) (launchTechnique target (target != runtime));
    # Refused where both delivery paths render it (the module and the public
    # mkSkill helper meet here): a reach must name a technique, and a route
    # composes that technique's model value spelling, so every eligible
    # technique is named, in kind order, as fallbacks
    # and each must carry a spelling. Disabled techniques are never named and
    # not refused.
    route = name: let
      node = techniques.${target}.${name};
    in
      if lib.trim node.modelArg == ""
      then throw "ai.programs.delegate-routing.runtimes.${target}.techniques.${lib.strings.escapeNixIdentifier name}.modelArg: name the model value spelling for techniques that pin model and effort"
      else
        phrase "Launch route" {
          inherit (node) modelArg;
          model =
            if name == "Agent with generated agent file"
            then "`${agentSet.${family.name}.id}`"
            else launchId family target;
          technique = name;
        };
  in
    if names == []
    then
      throw "ai.programs.delegate-routing.runtimes.${target}.techniques: enable a technique that pins model and effort${
        if target != runtime
        then "; from another harness it must be an external technique, otherwise ${target} must not be reached"
        else ""
      }"
    else lib.concatMapStringsSep (phrase "Launch fallback" {}) route names;
  reach = family: target:
    phrase (
      if target == runtime
      then "Native reach"
      else "External reach"
    ) {
      harness = target;
      launch = launch family target;
      pool = poolSuffix family target;
    };
  poolsText = lib.optionalString (pools != {}) (table "pools" skill.columns.pools {
      Description = item: item.pool.description;
      Measure = item:
        if item.pool.usage != null
        then phrase "Pool measured" {}
        else if item.pool.window == null
        then phrase "Pool unmeasured" {}
        else
          phrase "Pool window" {
            limit = toString item.pool.window.limit;
            resetDay = toString item.pool.window.resetDay;
            inherit (item.pool.window) unit;
          };
      Name = item: item.name;
      Reader = item:
        if item.command == null
        then phrase "Pool reader missing" {}
        else "`${item.command}`";
    }
    (lib.mapAttrsToList (name: declared: let
        # The public render and mkSkill helpers pass pool declarations
        # without the module's defaults, so default the optional fields here.
        pool =
          {
            description = "";
            usage = null;
            window = null;
          }
          // declared;
      in {
        inherit name pool;
        # Assertions own invalid-reader diagnostics, even if delivery forces
        # rendering before it collects the module's assertions.
        command =
          if pool.usage == null
          then null
          else techniques.${pool.usage.runtime}.${pool.usage.technique}.command or null;
      })
      pools));
  tier = name: let
    members = builtins.filter (family: family.tier == name) candidates;
  in
    lib.optionalString (members != []) ''
      ${phrase "Family table heading" {tier = name;}}

      ${table "families" skill.columns.families {
          "Avoid for" = family: family.avoidFor;
          "Effort (delegate)" = family: family.effort;
          Family = familyLabel;
          Launch = family: lib.concatMapStringsSep "; " (reach family) (targets family);
          Orchestration = family: family.orchestration or "";
          Pool = family: family.pool or "";
          "Use for" = family: family.useFor;
        }
        members}
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
      ${phrase "Technique table heading" {harness = target;}}

      ${lib.optionalString (delegates != {}) (table "techniques" (lib.removeAttrs skill.columns.techniques (lib.optional (!hasCommand) "Command")) {
          Command = item: command item.node;
          Kind = item: item.node.kind;
          Modes = item: lib.concatStringsSep "+" item.node.modes;
          Notes = item: item.node.notes;
          "Pins effort" = item: builtins.toJSON item.node.pinsEffort;
          "Pins model" = item: builtins.toJSON item.node.pinsModel;
          "Runs own subagents" = item: item.node.runsOwnSubagents;
          Technique = item: "`${item.name}`";
        }
        (lib.mapAttrsToList (name: node: {inherit name node;}) delegates))}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: node: "**${name} (${node.kind}):** ${lib.concatStringsSep "; " (lib.filter (value: value != "") [(command node) node.notes])}") info)}
    '';
  manual = target: ''
    ${phrase "Manual delegate heading" {harness = target;}}

    ${lib.concatMapStringsSep "\n" (family: "- ${familyLabel family}: ${launch family target}${poolSuffix family target}") (selected target)}

    ${techniqueBlock target true}
    ${phrase "Manual delegate note" {}}
  '';
  blocks = {
    families = lib.concatMapStringsSep "\n" tier tiers + lib.optionalString goRendered ("\n" + phrase "Provisional families" {});
    manual = lib.optionalString (manualExternalDelegates != []) (lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates));
    pools = poolsText;
    routing = routingText;
    techniques = lib.concatStringsSep "\n" ([(techniqueBlock runtime false)] ++ map (target: techniqueBlock target true) extras);
    workflows = workflowText;
  };
  # An entry naming a block that renders nothing is omitted whole.
  present = entry: lib.all (key: !(lib.hasInfix "{${key}}" entry.value.text) || blocks.${key} != "") (builtins.attrNames blocks);
  body = map (entry: lib.removeSuffix "\n" (lib.trimWith {end = true;} (fill entry.value.text blocks))) (builtins.filter present (entrySort.sort "delegate-routing.skill.entries" skill.entries));
in
  lib.concatStringsSep "\n\n" body + "\n"

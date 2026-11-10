{
  lib,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
  helperInstruction ? "",
  resolvedAgentFiles ? null,
  routing ? {},
  skill,
  workflows ? {},
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  view = import ./routing-view.nix {
    inherit lib runtime families models techniques pools resolvedAgentFiles extraRuntimes manualExternalDelegates;
  };
  inherit (import ./vocabulary.nix) delegateKinds tiers;
  inherit (view) candidates;
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
  opencodeGo = import ./opencode-go.nix {inherit lib;};
  goRendered = lib.any (family: family.vendor == opencodeGo.vendor) (candidates ++ map (route: route.family) view.manualRoutes);
  familyLabel = family: "${family.name} (${family.vendor}) `${family.match}`";
  launch = route:
    lib.concatMapStringsSep (phrase "Launch fallback" {}) (technique:
      # Validate each route even when its display phrase is disabled.
        builtins.seq technique (phrase "Launch route" {
          inherit (technique.node) modelArg;
          model =
            if technique.model.isPattern
            then phrase "Model pattern" {match = technique.model.value;}
            else "`${technique.model.value}`";
          technique = technique.name;
        }))
    route.techniques;
  poolSuffix = route: lib.optionalString (route.pool != null) (phrase "Pool binding" {inherit (route) pool;});
  reach = route:
    phrase (
      if route.target == runtime
      then "Native reach"
      else "External reach"
    ) {
      harness = route.target;
      launch = launch route;
      pool = poolSuffix route;
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
    view.readers);
  tier = name: let
    members = builtins.filter (family: family.tier == name) candidates;
  in
    lib.optionalString (members != []) ''
      ${phrase "Family table heading" {tier = name;}}

      ${table "families" skill.columns.families {
          "Avoid for" = family: family.avoidFor;
          "Effort (delegate)" = family: family.effort;
          Family = familyLabel;
          Launch = family: lib.concatMapStringsSep "; " reach (builtins.filter (route: route.family == family) view.routes);
          Orchestration = family: family.orchestration or "";
          Pool = family: family.pool or "";
          "Use for" = family: family.useFor;
        }
        members}
    '';
  techniqueBlock = target: externalOnly: asList: let
    nodes = lib.filterAttrs (_: node:
      node.enable
      && (!externalOnly || builtins.elem node.kind ["external" "introspect" "usage"]))
    techniques.${target};
    delegates = lib.filterAttrs (_: node: builtins.elem node.kind delegateKinds) nodes;
    info = lib.filterAttrs (_: node: builtins.elem node.kind ["introspect" "usage"]) nodes;
    hasCommand = lib.any (node: node.command != null) (builtins.attrValues delegates);
    command = node: lib.optionalString (node.command != null) "`${node.command}`";
    flag = condition: text: lib.optionalString (condition == true) "; ${text}";
    facts = node:
      lib.concatStrings [
        node.kind
        (lib.optionalString (node.modes != []) "; ${lib.concatStringsSep "+" node.modes}")
        (flag node.pinsModel "pins model")
        (flag node.pinsEffort "pins effort")
        (lib.optionalString (builtins.elem node.kind delegateKinds) "; runs own subagents: ${node.runsOwnSubagents}")
      ];
    # One compact line per technique: kind, modes, pins, subagent support,
    # then its command and notes.
    describe = group: lib.concatStringsSep "\n" (lib.mapAttrsToList (name: node: "- `${name}` (${facts node}): ${lib.concatStringsSep "; " (lib.filter (value: value != "") [(command node) node.notes])}") group);
  in
    lib.optionalString (nodes != {}) ''
      ${phrase (
        if asList
        then "Technique notes heading"
        else "Technique table heading"
      ) {harness = target;}}

      ${lib.optionalString (delegates != {} && !asList) (table "techniques" (lib.removeAttrs skill.columns.techniques (lib.optional (!hasCommand) "Command")) {
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

      ${
        if asList
        then describe nodes
        else lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: node: "**${name} (${node.kind}):** ${lib.concatStringsSep "; " (lib.filter (value: value != "") [(command node) node.notes])}") info)
      }
    '';
  manual = target: ''
    ${phrase "Manual delegate heading" {harness = target;}}

    ${lib.concatMapStringsSep "\n" (route: "- ${familyLabel route.family}: ${launch route}${poolSuffix route}${lib.optionalString (route.family.pool or "" != "") (phrase "Manual pool hint" {inherit (route.family) pool;})}") (builtins.filter (route: route.target == target) view.manualRoutes)}

    ${techniqueBlock target true true}

    ${phrase "Manual delegate note" {}}
  '';
  # Consumer {techniques} entries retain the table format; the shipped skill
  # uses compact notes. Both consume the same effective technique inventory.
  techniqueBlocks = asList:
    lib.concatStringsSep (
      if asList
      then "\n\n"
      else "\n"
    )
    ([(techniqueBlock runtime false asList)] ++ map (target: techniqueBlock target true asList) (lib.tail view.runtimes));
  blocks = {
    helper = helperInstruction;
    families = lib.concatMapStringsSep "\n" tier tiers + lib.optionalString goRendered ("\n\n" + phrase "OpenCode Go note" {});
    manual = lib.optionalString (manualExternalDelegates != []) (lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates));
    pools = poolsText;
    routing = routingText;
    techniqueNotes = techniqueBlocks true;
    techniques = techniqueBlocks false;
    workflows = workflowText;
  };
  # An entry naming a block that renders nothing is omitted whole.
  present = entry: lib.all (key: !(lib.hasInfix "{${key}}" entry.value.text) || blocks.${key} != "") (builtins.attrNames blocks);
  body = map (entry: lib.removeSuffix "\n" (lib.trimWith {end = true;} (fill entry.value.text blocks))) (builtins.filter present (entrySort.sort "delegate-routing.skill.entries" skill.entries));
in
  lib.concatStringsSep "\n\n" body + "\n"

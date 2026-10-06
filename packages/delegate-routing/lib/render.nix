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
  Use a technique only if it appears in your tool list; an external technique's command must be on PATH. The Modes column says where each tool usually appears; an agent cannot reliably tell which mode it is in, but it can see its tools.

  ${techniqueBlock runtime false}
  ${lib.concatMapStringsSep "\n" (target: techniqueBlock target true) extras}

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegates\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''

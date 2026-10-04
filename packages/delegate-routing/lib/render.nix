{
  lib,
  runtime,
  families,
  models,
  techniques,
  rules,
  procedure,
  roles,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  inherit (import ./select-families.nix {inherit lib;}) select;
  inherit (import ./vocabulary.nix) delegateKinds tiers;
  extras = lib.subtractLists manualExternalDelegates (lib.unique extraRuntimes);
  runtimes = [runtime] ++ extras;
  selected = target: select families models.${target};
  targets = family: builtins.filter (target: builtins.elem family (selected target)) runtimes;
  candidates = lib.unique (lib.concatMap selected runtimes);
  roleTier = role:
    if builtins.elem role.use tiers
    then role.use
    else (lib.findFirst (family: family.name == role.use) null candidates).tier;
  roleText = name: let
    role = roles.${name} or null;
    effort =
      if (role.effort or null) != null
      then role.effort
      else if (roles.default or null) != null
      then roles.default.effort or null
      else null;
  in
    lib.optionalString (role != null) "${
      if name == "default"
      then "Default for reasoning work"
      else "${lib.toUpper (builtins.substring 0 1 name)}${builtins.substring 1 (-1) name}"
    }: ${role.use}${lib.optionalString (effort != null) " at ${effort}"}.";
  rolesText = lib.concatStringsSep " " (lib.filter (text: text != "") (map roleText ["default" "writer" "reviewer"]));
  ceiling = lib.optionalString ((roles.default or null) != null) (let name = roleTier roles.default; in "${lib.toUpper (builtins.substring 0 1 name)}${builtins.substring 1 (-1) name} is the ceiling: go above it only when the user asks. Mechanical work still goes to the small tier (rule 1).");
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
        (["Technique" "Kind" "Pins model" "Pins effort" "Modes" "Notes"] ++ lib.optional hasCommand "Command")
        (lib.mapAttrsToList (name: node:
          [
            "`${name}`"
            node.kind
            (builtins.toJSON node.pinsModel)
            (builtins.toJSON node.pinsEffort)
            (lib.concatStringsSep "+" node.modes)
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
  ${rules}

  Use this skill for delegates and workflow nodes. Size each stage separately. If a model has no effort control, record effort as not applicable.

  Launch delegate CLIs from the current directory: it determines their permissions and configuration. Copilot has no per-delegate model or effort controls; work inline or use an external delegate.

  Sizing is a budget decision, not a rigor decision: a cheaper delegate still owes the same evidence. Size up a task that cannot meet the bar.

  ${lib.optionalString (extras != [] || manualExternalDelegates != []) "If one model stands out, use it unless its pool is exhausted; among close candidates, prefer the pool with more remaining allowance. Check usage with the runtime's command; if none is available, prefer the other pool among close candidates."}

  **Prefer workflows.** When work has more than one stage or several independent pieces, build it as a workflow graph with model and effort set on every node, not as a series of single subagent calls. Use a lone subagent only for one self-contained task, through a technique that pins its model and effort. If this runtime has no workflow technique, build the graph from pinned subagents or external launches.

  **Inheritance.** A technique that does not pin a value inherits it from the session. An interactive session cannot reliably know its own model or effort (`/model` and `/effort` change them), so treat an inheriting technique as unsized there. A headless delegate inherits what it was launched with: state the model and effort in every external launch brief, and a delegate told its launch values may use an inheriting technique when those values match its choice.

  ## delegate sizing

  Each row is a family: pick the id with the highest version that matches its pattern in the live model list, comparing version numbers segment by segment (6.1 > 6 > 5.6), and use the runtime's own spelling from the introspection step (Claude's interactive tools take the alias, e.g. `opus`).

  ${lib.optionalString (rolesText != "") "**Roles.** ${rolesText} ${ceiling}"}

  ${lib.optionalString (builtins.length (lib.unique (map (family: family.vendor) candidates)) > 1) "Rows span more than one vendor, so a reviewer may come from a different vendor than the writer."}

  ${lib.concatMapStringsSep "\n" tier tiers}
  Use a technique only if it appears in your tool list; an external technique's command must be on PATH. The Modes column says where each tool usually appears; an agent cannot reliably tell which mode it is in, but it can see its tools.

  ${techniqueBlock runtime false}
  ${lib.concatMapStringsSep "\n" (target: techniqueBlock target true) extras}
  ${procedure}

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegates\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''

{
  lib,
  runtime,
  families,
  models,
  techniques,
  rules,
  procedure,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  select = import ./select-families.nix {inherit lib;};
  extras = lib.subtractLists manualExternalDelegates (lib.unique extraRuntimes);
  runtimes = [runtime] ++ extras;
  selected = target: select families models.${target};
  targets = family: builtins.filter (target: builtins.elem family (selected target)) runtimes;
  candidates = lib.unique (lib.concatMap selected runtimes);
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
      (node.enable or true)
      && (!externalOnly || builtins.elem node.kind ["external" "introspect" "usage"]))
    techniques.${target};
    delegates = lib.filterAttrs (_: node: builtins.elem node.kind ["workflow" "subagent" "external"]) nodes;
    info = lib.filterAttrs (_: node: builtins.elem node.kind ["introspect" "usage"]) nodes;
    hasCommand = lib.any (node: (node.command or null) != null) (builtins.attrValues delegates);
    command = node: lib.optionalString ((node.command or null) != null) "`${node.command}`";
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
            (node.notes or "")
          ]
          ++ lib.optional hasCommand (command node))
        delegates))}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: node: "**${name} (${node.kind}):** ${command node} ${node.notes or ""}") info)}
    '';
  manual = target: ''
    ${lib.concatMapStringsSep "\n" (family: "- ${familyLabel family}") (selected target)}

    ${techniqueBlock target true}
    Not a candidate for auto-selection; use only when the user names it.
  '';
in ''
  ${lib.optionalString rules.enable rules.text}

  Use this skill for delegates and workflow nodes. Size each stage separately. If a model has no effort control, record effort as not applicable.

  Launch delegate CLIs from the current directory: it determines their permissions and configuration. Copilot has no per-delegate model or effort controls; work inline or use an external delegate.

  Sizing is a budget decision, not a rigor decision: a cheaper delegate still owes the same evidence. Size up a task that cannot meet the bar. If one model stands out, use it unless its pool is exhausted; among close candidates, prefer the pool with more remaining allowance. Check usage with the runtime's command; if none is available, prefer the other pool among close candidates.

  **Prefer workflows.** When work has more than one stage or several independent pieces, build it as a workflow graph with model and effort set on every node, not as a series of single subagent calls. Use a lone subagent only for one self-contained task, through a technique that pins its model and effort. If this runtime has no workflow technique, build the graph from pinned subagents or external launches.

  **Inheritance.** A technique that does not pin a value inherits it from the session. An interactive session cannot reliably know its own model or effort (`/model` and `/effort` change them), so treat an inheriting technique as unsized there. A headless delegate inherits what it was launched with: state the model and effort in every external launch brief, and a delegate told its launch values may use an inheriting technique when those values match its choice.

  ## delegate sizing

  Each row is a family: pick the newest id in the live model list matching its pattern, and use the runtime's own spelling from the introspection step (Claude's interactive tools take the alias, e.g. `opus`).

  ${lib.optionalString (builtins.length (lib.unique (map (family: family.vendor) candidates)) > 1) "Rows span more than one vendor, so a reviewer may come from a different vendor than the writer."}

  ${lib.concatMapStringsSep "\n" tier ["frontier" "strong" "mid" "small"]}
  ${techniqueBlock runtime false}
  ${lib.concatMapStringsSep "\n" (target: techniqueBlock target true) extras}
  ${lib.optionalString procedure.enable procedure.text}

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegates\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''

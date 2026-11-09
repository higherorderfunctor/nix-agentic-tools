# Normalized launch reaches and registered readers, independent of skill prose.
{
  lib,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
  resolvedAgentFiles ? null,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  selection = import ./select-families.nix {inherit lib;};
  inherit (import ./vocabulary.nix) delegateKinds;
  runtimes = selection.automatic {inherit runtime extraRuntimes manualExternalDelegates;};
  selected = target: selection.select families models.${target};
  candidates = selection.candidates families models runtimes;
  agentFiles = import ./agent-files.nix {inherit lib;};
  agentSet =
    if resolvedAgentFiles != null
    then resolvedAgentFiles
    else agentFiles.resolve agentFiles.facts.models (selected "claude");
  kindOrder = {
    external = 3;
    subagent = 1;
    workflow = 2;
  };
  # Other harnesses can be reached only through external commands.
  launchTechniques = target: let
    eligible = lib.filterAttrs (_: node:
      node.enable
      && node.launchRoute
      && builtins.elem node.kind delegateKinds
      && node.pinsModel == true
      && node.pinsEffort == true
      && (target == runtime || node.kind == "external"))
    techniques.${target};
  in
    builtins.sort
    (a: b: kindOrder.${eligible.${a}.kind} < kindOrder.${eligible.${b}.kind})
    (builtins.attrNames eligible);
  reach = family: target: let
    names = builtins.filter (name: name != "Agent with generated agent file" || agentSet ? ${family.name}) (launchTechniques target);
    technique = name: let
      node = techniques.${target}.${name};
      agent =
        if name == "Agent with generated agent file"
        then agentSet.${family.name}
        else null;
      id =
        if agent != null
        then agent.id
        else family.example.${target} or "";
    in
      # Both module delivery and direct mkSkill callers refuse missing model
      # spelling here; disabled/non-launch techniques never enter this list.
      if lib.trim node.modelArg == ""
      then throw "ai.programs.delegate-routing.runtimes.${target}.techniques.${lib.strings.escapeNixIdentifier name}.modelArg: name the model value spelling for techniques that pin model and effort"
      else {
        inherit agent name node;
        model = {
          isPattern = lib.trim id == "";
          value =
            if lib.trim id != ""
            then id
            else family.match;
        };
      };
  in {
    inherit target;
    # Direct callers can omit the module's nullable option default.
    family = {maker = null;} // family;
    pool = selection.poolFor family target;
    techniques =
      if names == []
      then
        throw "ai.programs.delegate-routing.runtimes.${target}.techniques: enable a technique that pins model and effort${
          if target != runtime
          then "; from another harness it must be an external technique, otherwise ${target} must not be reached"
          else ""
        }"
      else map technique names;
  };
in {
  inherit candidates runtimes;
  routes = lib.concatMap (family:
    map (reach family) (builtins.filter (target: builtins.elem family (selected target)) runtimes))
  candidates;
  manualRoutes = lib.concatMap (target: map (family: reach family target) (selected target)) (lib.unique manualExternalDelegates);
  readers =
    lib.mapAttrsToList (name: declared: let
      # Direct render/mkSkill callers may omit the module's optional defaults.
      pool =
        {
          description = "";
          usage = null;
          window = null;
        }
        // declared;
    in {
      inherit name pool;
      # The module's assertions own invalid-reader diagnostics, even when
      # rendering is forced before assertion collection. Inventory every pool,
      # including readers on runtimes outside automatic and manual targets.
      command =
        if pool.usage == null
        then null
        else techniques.${pool.usage.runtime}.${pool.usage.technique}.command or null;
    })
    pools;
}

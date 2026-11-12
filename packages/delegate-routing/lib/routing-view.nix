# Normalized launch reaches and registered readers, independent of skill prose.
{
  lib,
  catalog ? null,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
  picker ? null,
  resolvedAgentFiles ? null,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  selection = import ./select-families.nix {inherit lib;};
  inherit (import ./vocabulary.nix) delegateKinds effortLevels;
  runtimes = selection.automatic {inherit runtime extraRuntimes manualExternalDelegates;};
  graphModels = target:
    if catalog == null
    then null
    else catalog.modelsFor target;
  resolvedModel = family: target: let
    ids = graphModels target;
    resolved =
      if ids == null
      then {}
      else
        agentFiles.resolve ids [
          (family // {example.claude = family.example.${target} or "";})
        ];
    id =
      if target == "claude" && resolvedAgentFiles != null && resolvedAgentFiles ? ${family.name}
      then resolvedAgentFiles.${family.name}.id
      else if resolved ? ${family.name}
      then resolved.${family.name}.id
      else null;
  in
    if catalog != null && catalog.runtimes ? ${target} && id != null && !lib.elem id ids
    then throw "delegate-routing: model ${id} is not reachable in catalog runtime ${target}."
    else id;
  selected = target:
    lib.filter (family:
      catalog == null || !(catalog.runtimes ? ${target}) || resolvedModel family target != null)
    (selection.select families models.${target});
  candidates = lib.unique (lib.concatMap selected runtimes);
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
        if catalog != null && catalog.runtimes ? ${target}
        then resolvedModel family target
        else if agent != null
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
    family = {defaultEffort = null;} // family;
    pool = selection.poolFor catalog family target (resolvedModel family target);
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
  routes = lib.concatMap (family:
    map (reach family) (builtins.filter (target: builtins.elem family (selected target)) runtimes))
  candidates;
  resolvePickerEntry = entry: let
    matches = builtins.filter (route:
      builtins.hasAttr entry.technique techniques.${route.target}
      && ((route.family.example.${route.target} or "") == entry.model || builtins.match (agentFiles.pattern route.family.match) entry.model != null))
    routes;
    route = lib.head matches;
    node = techniques.${route.target}.${entry.technique};
    # A picker is a one-shot external command that pins model and effort; reach
    # already refused an empty modelArg for every such technique on a route.
    usable =
      node.enable
      && node.launchRoute
      && node.kind == "external"
      && node.pinsModel == true
      && node.pinsEffort == true
      && node.pickerCommand != null;
    # One concrete model: a glob would let the pattern match stand in for it.
    concrete = lib.trim entry.model != "" && !lib.any (char: lib.hasInfix char entry.model) ["*" "?" "["];
  in
    if builtins.length matches != 1 || !usable || !concrete || !(builtins.elem entry.effort effortLevels)
    then null
    else {
      inherit (entry) effort model technique;
      runtime = route.target;
      inherit (node.pickerCommand) command toolFree;
      family = route.family.name;
      inherit (route) pool;
    };
in {
  inherit candidates effortLevels runtimes;
  pickerEntries = let
    # A family-named default takes the family's resolved id and is dropped when
    # none resolves; a model-named default passes through.
    inheritFamilyModel = entry:
      if entry ? family
      then lib.optional (agentSet ? ${entry.family}) (removeAttrs entry ["family"] // {model = agentSet.${entry.family}.id;})
      else [entry];
  in
    if picker == null
    then
      # Inherited defaults may be outside the selected model/reach or have a
      # disabled technique. Explicit entries use this same resolver but refuse.
      builtins.filter (entry: entry != null) (map resolvePickerEntry
        (lib.concatMap inheritFamilyModel
          (import ./defaults.nix {
            inherit lib;
            claudeUsageScript = null;
            codexUsageScript = null;
          }).picker.${
            runtime
          }.entries))
    else if !lib.allUnique picker.entries
    then throw "ai.programs.delegate-routing.runtimes.${runtime}.picker.entries: duplicate technique/model/effort tuple"
    else
      map (entry: let
        resolved = resolvePickerEntry entry;
      in
        if resolved == null
        then throw "ai.programs.delegate-routing.runtimes.${runtime}.picker.entries: require one configured concrete model family, enabled external one-shot technique, model/effort pins and non-empty picker command"
        else resolved)
      picker.entries;
  familyNames = map (family: family.name) (selection.flatten families);
  inherit routes;
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

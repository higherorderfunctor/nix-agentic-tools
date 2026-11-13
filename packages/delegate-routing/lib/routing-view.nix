# Normalized launch reaches and registered readers, independent of skill prose.
{
  lib,
  catalog,
  cpaRoutes ? {},
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
  # Null means no declared CPA reach, rather than an empty allowed model set.
  offered = target: cpaRoutes.${target} or null;
  # Select original served spellings so agent files and other launch techniques agree.
  resolvedModel = family: target: let
    offers = offered target;
    resolved = agentFiles.resolve (map (offer: offer.model) offers) [
      # agent-files.resolve reads only example.claude, including for other runtimes.
      (family // {example.claude = family.example.${target} or "";})
    ];
  in
    if offers == null
    then null
    else if target == "claude" && resolvedAgentFiles != null && resolvedAgentFiles ? ${family.name}
    then resolvedAgentFiles.${family.name}.id
    else resolved.${family.name}.id or null;
  selected = target:
    lib.filter (family: offered target == null || resolvedModel family target != null)
    (selection.select families models.${target});
  candidates = lib.unique (lib.concatMap selected runtimes);
  agentFiles = import ./agent-files.nix {inherit lib;};
  agentSet =
    if resolvedAgentFiles != null
    then resolvedAgentFiles
    else
      agentFiles.resolve (
        if offered "claude" == null
        then agentFiles.facts.models
        else map (offer: offer.model) (offered "claude")
      ) (selected "claude");
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
        else if offered target != null
        then resolvedModel family target
        else family.example.${target} or "";
    in
      # Both module delivery and direct mkSkill callers refuse missing model
      # spelling here; disabled/non-launch techniques never enter this list.
      if lib.trim node.modelArg == ""
      then throw "ai.programs.delegate-routing.runtimes.${target}.techniques.${lib.strings.escapeNixIdentifier name}.modelArg: name the model value spelling for techniques that pin model and effort"
      else
        builtins.seq (
          if lib.trim id == ""
          then null
          else selection.validateId catalog (offered target) id
        ) {
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
    pool = family.pools.${target} or null;
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
    else if picker == null && offered route.target != null && !lib.any (offer: offer.model == entry.model) (offered route.target)
    then null
    else
      builtins.seq (selection.validateId catalog (offered route.target) entry.model) {
        inherit (entry) effort model technique;
        runtime = route.target;
        inherit (node.pickerCommand) command outputFormat resumeCommand sessionIdSource toolFree;
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
  # Reader scopes name configured families even outside this runtime's reach.
  poolFamilies = lib.mapAttrs (pool: _:
    lib.sort builtins.lessThan (lib.unique (map (family: family.name)
      (builtins.filter (family: builtins.elem pool (builtins.attrValues (family.pools or {})))
        (selection.flatten families)))))
  pools;
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
    # Credential preview scopes use catalog IDs, never helper family bindings.
    (lib.filterAttrs (_: pool: (pool.limits or {}) == {} && ((pool.usage or null) == null || (pool.usage.readerPool or null) == null)) pools);
}

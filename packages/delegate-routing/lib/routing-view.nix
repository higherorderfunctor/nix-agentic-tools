# Normalized launch reaches and registered readers, independent of skill prose.
{
  lib,
  runtime,
  families,
  models,
  techniques,
  pools ? {},
  lowWaterMark ? (import ./vocabulary.nix).lowWaterMark,
  picker ? null,
  resolvedAgentFiles ? null,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
}: let
  selection = import ./select-families.nix {inherit lib;};
  inherit (import ./vocabulary.nix) delegateKinds effortLevels;
  runtimes = selection.automatic {inherit runtime extraRuntimes manualExternalDelegates;};
  selected = target: selection.select families models.${target};
  candidates = selection.candidates families models runtimes;
  routedFamilies = candidates ++ lib.concatMap selected (lib.unique manualExternalDelegates);
  familyMakers = builtins.listToAttrs (map (family: {
    inherit (family) name;
    value =
      if (family.maker or null) != null
      then family.maker
      else if builtins.elem family.vendor ["anthropic" "openai" "zhipu"]
      then family.vendor
      else if builtins.elem family routedFamilies
      then throw "ai.programs.delegate-routing.families.${family.vendor}.${family.name}.maker: declare the model maker for a selected family"
      # Keep all configured names available to exclude validation without
      # rejecting an unused custom family that has not declared its maker.
      else null;
  }) (selection.flatten families));
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
        if target == "claude" && agentSet ? ${family.name}
        then agentSet.${family.name}.id
        else family.example.${target} or "";
    in
      # Both module delivery and direct mkSkill callers refuse missing model
      # spelling here; disabled/non-launch techniques never enter this list.
      if lib.trim node.modelArg == ""
      then throw "ai.programs.delegate-routing.runtimes.${target}.techniques.${lib.strings.escapeNixIdentifier name}.modelArg: name the model value spelling for techniques that pin model and effort"
      else {
        inherit agent name node;
        model = {
          # Pins carry known effort support even without a live catalog. Claude's
          # current release supplies its levels; other pins certify the default.
          efforts =
            if (family.defaultEffort or null) == null
            then []
            else if target == "claude"
            then agentFiles.facts.effortLevels
            else [family.defaultEffort];
          isPattern = lib.trim id == "";
          value =
            if lib.trim id != ""
            then id
            else family.match;
        };
      };
  in {
    inherit target;
    family = {defaultEffort = null;} // family // {maker = familyMakers.${family.name};};
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
  routes = lib.concatMap (family:
    map (reach family) (builtins.filter (target: builtins.elem family (selected target)) runtimes))
  candidates;
  resolvePickerEntry = entry: let
    hasFamily = (entry.family or null) != null;
    hasModel = (entry.model or null) != null;
    matches = builtins.filter (route:
      builtins.hasAttr entry.technique techniques.${route.target}
      && (
        if hasFamily
        then route.family.name == entry.family
        else hasModel && ((route.family.example.${route.target} or "") == entry.model || builtins.match (agentFiles.pattern route.family.match) entry.model != null)
      ))
    routes;
    route = lib.head matches;
    node = techniques.${route.target}.${entry.technique};
    pin = (lib.findFirst (technique: technique.name == entry.technique) null route.techniques).model;
    model =
      if hasModel
      then entry.model
      else if pin.isPattern
      then ""
      else pin.value;
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
    concrete = lib.trim model != "" && !lib.any (char: lib.hasInfix char model) ["*" "?" "["];
  in
    if hasFamily == hasModel || builtins.length matches != 1 || !usable || !concrete || !(builtins.elem entry.effort effortLevels)
    then null
    else {
      inherit (entry) effort technique;
      inherit model;
      runtime = route.target;
      inherit (node.pickerCommand) command toolFree;
      family = route.family.name;
      inherit (route) pool;
    };
in {
  inherit candidates effortLevels familyMakers lowWaterMark runtimes;
  pickerEntries = let
    entries =
      if picker == null
      then
        # Inherited defaults outside the selected reach are omitted; explicit
        # entries use the same resolver and refuse an unresolved model.
        builtins.filter (entry: entry != null) (map resolvePickerEntry
          (import ./defaults.nix {
            inherit lib;
            claudeUsageScript = null;
            codexUsageScript = null;
          }).picker.${
            runtime
          }.entries)
      else
        map (entry: let
          resolved = resolvePickerEntry entry;
        in
          if resolved == null
          then throw "ai.programs.delegate-routing.runtimes.${runtime}.picker.entries: require exactly one of family or model resolving to one configured concrete model family, enabled external one-shot technique, model/effort pins and non-empty picker command"
          else resolved)
        picker.entries;
    samePool = entry: builtins.filter (other: other.pool == entry.pool) entries;
    duplicate = lib.findFirst (entry: builtins.length (samePool entry) > 1) null entries;
  in
    if duplicate != null
    then throw "ai.programs.delegate-routing.runtimes.${runtime}.picker.entries: duplicate pool ${builtins.toJSON duplicate.pool}: ${lib.concatMapStringsSep ", " (entry: "${entry.model} (${entry.technique}, ${entry.effort})") (samePool duplicate)}"
    else entries;
  familyNames = map (family: family.name) (selection.flatten families);
  inherit routes;
  manualRoutes = lib.concatMap (target: map (family: reach family target) (selected target)) (lib.unique manualExternalDelegates);
  readers =
    lib.mapAttrsToList (name: declared: let
      # Direct render/mkSkill callers may omit the module's optional defaults.
      pool =
        {
          description = "";
          preference = 0;
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

# Runtime declarations are the only authority for normalized delivery support.
# An omitted surface is unsupported; a declared surface keeps its option tree
# on both backends, even when its writer exists on only one.
{lib}: {
  appRecord,
  backend,
  config,
  entries,
  message,
  nonEmpty,
  present,
  sharedSurfaces,
}: let
  runtime = appRecord.name;
  cfg = config.ai.${runtime};
  namespaces = import ./optionNamespaces.nix {inherit lib;};
  declarations = appRecord.surfaceSupport or {};
  supported = surface: (declarations.${surface}.backends or []) != [];
  defaultReason = "${runtime}'s surfaceSupport does not consume this shared surface.";
  # A runtime unit's path relative to `ai.<runtime>`, inside its namespace.
  runtimePath = surface: namespaces.pool appRecord surface ++ [surface];
  root = surface: {
    path = ["ai" surface];
    value = config.ai.${surface};
  };
  # The inputs a consumer sets a surface through, most specific first: the
  # runtime's own pool where its record declares one, then the portable root.
  units = surface:
    lib.optional (supported surface && lib.hasAttrByPath (runtimePath surface) cfg) {
      path = ["ai" runtime] ++ runtimePath surface;
      value = lib.getAttrFromPath (runtimePath surface) cfg;
    }
    ++ [(root surface)];
  # A gap is one field a delivered surface drops: in every keyed entry (`each`,
  # root or runtime pool), otherwise in the portable root.
  gapWarnings = surface: gap: let
    candidates =
      if gap.each or false
      then entries surface
      else [(root surface)];
    warnings = entry: let
      args = entry // {inherit cfg;};
      reason =
        if builtins.isFunction gap.reason
        then gap.reason args
        else gap.reason;
    in
      lib.optional (nonEmpty (lib.attrByPath gap.path null entry.value) && (gap.when or (_: true)) args)
      (message (entry.path ++ gap.path) reason);
  in
    lib.concatMap warnings candidates;
  # An undelivered surface warns once, naming the most specific input set.
  surfaceWarnings = surface: let
    declaration = declarations.${surface} or {};
  in
    if builtins.elem backend (declaration.backends or [])
    then lib.concatMap (gapWarnings surface) (declaration.gaps or [])
    else
      lib.take 1 (map (unit: message unit.path (declaration.reason or defaultReason))
        (lib.filter (unit: present unit.path unit.value) (units surface)));
in {
  warnings = lib.concatMap surfaceWarnings sharedSurfaces;
}

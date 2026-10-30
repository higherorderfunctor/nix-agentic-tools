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
  reasons = import ./supportReasons.nix runtime;
  # A runtime unit's path relative to `ai.<runtime>`, inside its namespace.
  runtimePath = surface: namespaces.pool appRecord surface ++ [surface];
  root = surface: {
    path = ["ai" surface];
    value = config.ai.${surface};
  };
  # The inputs a consumer sets a surface through, most specific first: the
  # runtime's own pool, the portable root, then the runtime's public
  # normalized option. Both runtime options exist only where some backend
  # delivers the surface. The normalized option defaults to the fold of the
  # other two, so it is reached only when both are empty, where any value it
  # holds was set on it directly.
  units = surface: let
    runtimeUnit = relative:
      lib.optional (supported surface && lib.hasAttrByPath relative cfg) {
        path = ["ai" runtime] ++ relative;
        value = lib.getAttrFromPath relative cfg;
      };
  in
    runtimeUnit (runtimePath surface)
    ++ [(root surface)]
    ++ runtimeUnit (namespaces.pool appRecord surface ++ ["normalized" surface]);
  # A gap is one field a delivered surface drops: in every keyed entry (`each`,
  # root or runtime pool), otherwise in the portable root.
  gapWarnings = surface: gap: let
    candidates =
      if gap.each or false
      then entries surface
      else [(root surface)];
    warnings = entry: let
      args = entry // {inherit backend cfg;};
      reason =
        if builtins.isFunction gap.reason
        then gap.reason args
        else gap.reason;
    in
      lib.optional (nonEmpty (lib.attrByPath gap.path null entry.value) && (gap.when or (_: true)) args)
      (message (entry.path ++ gap.path) reason);
  in
    lib.concatMap warnings candidates;
  # Settings warn per field when undelivered or unlisted; other undelivered
  # surfaces warn once. Each warning names the most specific input set.
  # findFirst leaves later inputs (the normalized fold) unforced.
  surfaceWarnings = surface: let
    declaration = declarations.${surface} or {};
    delivered = builtins.elem backend (declaration.backends or []);
    inert = lib.findFirst (unit: present unit.path unit.value) null (units surface);
  in
    (
      if surface == "settings"
      then
        lib.concatMap (field: let
          requested = lib.findFirst (unit: lib.attrByPath [field] null unit.value != null) null (units surface);
          reason =
            if delivered
            then reasons.settingsField
            else declaration.reason or reasons.surface;
        in
          lib.optional (!(delivered && builtins.elem field (declaration.fields or [])) && requested != null)
          (message (requested.path ++ [field]) reason))
        (builtins.attrNames (config.ai.settings or {}))
      else lib.optional (!delivered && inert != null) (message inert.path (declaration.reason or reasons.surface))
    )
    ++ lib.optionals delivered (lib.concatMap (gapWarnings surface) (declaration.gaps or []));
in {
  warnings = lib.concatMap surfaceWarnings sharedSurfaces;
}

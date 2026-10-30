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
  # other two, so it is reached only when neither earlier input holds the
  # requested surface or field.
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
  holds = path: unit: nonEmpty (lib.attrByPath path null unit.value);
  requestAt = surface: path: lib.findFirst (holds path) null (units surface);
  # A gap is one field a delivered surface drops: in every keyed entry (`each`,
  # root or runtime pool), otherwise at the most specific input with that field
  # set (runtime pool, root, normalized), once even when the root is copied down.
  gapWarnings = surface: gap: let
    requested = requestAt surface gap.path;
    candidates =
      if gap.each or false
      then entries surface
      else lib.optional (requested != null) requested;
    warnings = entry: let
      args = entry // {inherit backend cfg;};
      reason =
        if builtins.isFunction gap.reason
        then gap.reason args
        else gap.reason;
    in
      lib.optional (holds gap.path entry && (gap.when or (_: true)) args)
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
          # Structured inference defaults to all-null fields, not a request.
          requested = requestAt surface [field];
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

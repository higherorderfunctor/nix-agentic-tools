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
  declarations = appRecord.surfaceSupport or {};
  supported = surface: (declarations.${surface}.backends or []) != [];
  defaultReason = "${runtime}'s surfaceSupport does not consume this shared surface.";
  units = surface:
    [
      {
        path = ["ai" surface];
        value = config.ai.${surface};
      }
    ]
    ++ lib.optional (supported surface && cfg ? ${surface}) {
      path = ["ai" runtime surface];
      value = cfg.${surface};
    };
  gapWarnings = surface: gap: let
    candidates =
      if gap.each or false
      then entries surface
      else units surface;
    tail = gap.path or [];
    warnings = entry: let
      value = lib.attrByPath tail null entry.value;
      args =
        entry
        // {
          inherit backend cfg config value;
          entryValue = entry.value;
        };
      # Scalar overrides inherit on null. An effective gap diagnoses the
      # winning root/runtime input once, rather than both declarations.
      selected =
        !(gap.effective or false)
        || (builtins.length entry.path == 3)
        == (lib.attrByPath ([surface] ++ tail) null cfg != null);
      active =
        builtins.elem backend (gap.backends or ["devenv" "hm"])
        && (!(gap.rootOnly or false) || builtins.length entry.path == 2)
        && selected
        && (
          if tail == []
          then present entry.path
          else nonEmpty value
        )
        && (gap.when or (_: true)) args;
      reason =
        if builtins.isFunction gap.reason
        then gap.reason args
        else gap.reason;
    in
      lib.optional active (message (entry.path ++ tail) reason);
  in
    lib.concatMap warnings candidates;
  surfaceWarnings = surface: let
    declaration = declarations.${surface} or {};
    delivered = builtins.elem backend (declaration.backends or []);
  in
    if !delivered
    then
      lib.concatMap (unit:
        lib.optional (present unit.path)
        (message unit.path (declaration.reason or defaultReason))) (units surface)
    else lib.concatMap (gapWarnings surface) (declaration.gaps or []);
in {
  warnings = lib.concatMap surfaceWarnings sharedSurfaces;
}

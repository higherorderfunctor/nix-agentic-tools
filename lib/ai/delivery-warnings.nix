# Diagnostics are separate from lowering: warnings must neither change pool
# precedence nor force source-backed content discarded by final-file overrides.
#
# Option paths are LISTS of attribute keys from end to end, never dotted
# strings. A consumer key may contain a dot of its own — a `foo.bar.md` rule
# lands at key `foo.bar` — so a path re-split on "." silently addresses the
# wrong option, and a message assembled by string concatenation names one that
# cannot be pasted back. `lib.showOption` is the only renderer.
{lib}: {
  appRecord,
  backend,
  config,
  options ? {},
  # Path each context/rule unit lands in (the record's `contentTargets`), the
  # paths the shared AGENTS.md owner holds, and whether the runtime has
  # context at all. All empty for a caller that knows none of them.
  contentTargets ? {},
  sharedTargets ? [],
  hasContext ? false,
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  runtimeFiles = import ./runtime-files.nix {inherit lib;};
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  runtime = appRecord.name;
  cfg = config.ai.${runtime};
  namespaces = import ./app/optionNamespaces.nix {inherit lib;};
  supports = pool: (appRecord.surfaceSupport.${pool}.backends or []) != [];
  # A per-runtime pool's option path, inside the record's namespace, and its value.
  poolPath = pool: ["ai" runtime] ++ namespaces.pool appRecord pool ++ [pool];
  poolValue = pool: lib.attrByPath (namespaces.pool appRecord pool ++ [pool]) null cfg;
  get = path: lib.attrByPath path null config;
  live = surface: pool:
    lib.filterAttrs
    (_: value: value != null && (surface != "rules" || value.enable != false))
    pool;
  nonEmpty = value:
    if value == null
    then false
    else if lib.isDerivation value
    then true
    else if builtins.isAttrs value
    then lib.any nonEmpty (builtins.attrValues value)
    else if builtins.isList value
    then value != []
    else if builtins.isString value
    then value != ""
    else true;
  keyed = policy.keyedSurfaces;
  rootRemaining = surface:
    builtins.removeAttrs (live surface (config.ai.${surface} or {}))
    (
      if supports surface
      then builtins.attrNames (lib.defaultTo {} (poolValue surface))
      else []
    );
  present = path: let
    surface = lib.last path;
    value = get path;
  in
    # Root requests warn even when the runtime cannot withdraw them. Keyed
    # pools still subtract per-runtime replacements and tombstones by name.
    if builtins.elem surface keyed
    then
      (
        if builtins.length path == 2
        then rootRemaining surface
        else
          live surface (
            if value == null
            then {}
            else value
          )
      )
      != {}
    else if surface == "context"
    then aiCommon.hasContent value
    else nonEmpty value;
  message = path: reason: "${lib.showOption path} is set but ${backend} does not deliver it to ${runtime} (reason: ${reason})";
  gapRows = builtins.filter (row:
    row.ecosystem
    == runtime
    && row.mode == backend
    && (row.primitive == "notApplicable" || row ? deliveryGap))
  (lib.concatMap policy.writersOf policy.rows);
  normalizedPath = path:
    builtins.length path
    >= 2
    && builtins.elem (builtins.elemAt path 1) config.ai.internal.sharedSurfaces
    || lib.any (pool: supports pool && lib.lists.hasPrefix (poolPath pool) path) config.ai.internal.sharedSurfaces;
  decomposition = import ./app/decompose.nix {inherit lib;} {
    inherit appRecord backend config entries message nonEmpty present;
    sharedSurfaces = config.ai.internal.sharedSurfaces;
  };
  rowWarnings = lib.concatMap (row:
    map (path: message path (row.deliveryGap or row.reason))
    (builtins.filter (path:
      !(normalizedPath path)
      && present path
      && (!(row.warnOnlyExplicit or false)
        || (lib.attrByPath (path ++ ["highestPrio"]) 1500 options) < 1500)) (row.inputOptions or [])))
  gapRows;
  entries = pool:
    lib.optionals (supports pool) (
      (lib.mapAttrsToList (name: value: {
        inherit name value;
        path = ["ai" pool name];
        root = true;
      }) (rootRemaining pool))
      ++ (lib.mapAttrsToList (name: value: {
          inherit name value;
          path = poolPath pool ++ [name];
          root = false;
        })
        (live pool (lib.defaultTo {} (poolValue pool))))
    );
  fieldWarning = entry: field: reason:
    lib.optional (
      if builtins.elem field ["env" "headers"]
      then (entry.value.${field} or {}) != {}
      else nonEmpty (entry.value.${field} or null)
    ) (message (entry.path ++ [field]) reason);
  mcpWarnings = lib.concatMap (entry: let
    srv = entry.value;
    http = (srv.url or null) != null;
    raw = !http && (srv.command or null) != null;
    ignored =
      if http
      then ["args" "command" "env" "package" "settings"]
      else ["headers" "timeout"] ++ lib.optionals raw ["settings"];
  in
    lib.concatMap (field:
      fieldWarning entry field
      (
        if http
        then "HTTP MCP entries use url; this stdio field is not rendered."
        else if field == "settings"
        then "An explicit MCP command bypasses typed package settings."
        else "This HTTP MCP field is not rendered for stdio."
      ))
    ignored) (entries "mcpServers");
  # A context or rule unit whose file is switched off or replaced. The unit
  # was requested and resolved, and the file that would carry it either has
  # `content.enable = false` or carries a consumer's own bytes instead of the
  # generated ones, so nothing delivers it: the drop that used to be silent.
  # A replacement is recognized by the `_generated` marker every generator
  # sets inside its own `content` definition, which any consumer `content`
  # definition discards whole (lib/ai/delivery-options.nix).
  #
  # The final entry is the runtime's own, except for a shared AGENTS.md key
  # on devenv, whose final entry is the owner's; there the override is named
  # on whichever enabled runtime's public entry states it.
  finalEntry = path:
    if builtins.elem path sharedTargets
    then config.ai.internal.files.${path} or null
    else cfg.files.${path} or null;
  switchedOff = entry: !(runtimeFiles.isLive entry);
  replaced = entry: runtimeFiles.isLive entry && !(entry.content._generated or false);
  overridingRuntime = test: path: let
    overrides = name: let
      other = config.ai.${name} or {};
    in
      (other.enable or false)
      && (other.files or {}) ? ${path}
      && test other.files.${path};
    candidates = builtins.attrNames (config.ai.internal.agentsMdTargets or {});
  in
    if builtins.elem path sharedTargets
    then lib.findFirst overrides runtime (lib.sort lib.lessThan candidates)
    else runtime;
  # The reason a unit's file does not carry it, or null when it does.
  dropReason = path: let
    entry = finalEntry path;
    option = test: tail: lib.showOption (["ai" (overridingRuntime test path) "files" path] ++ tail);
  in
    if entry == null
    then null
    else if switchedOff entry
    then "${option switchedOff ["content" "enable"]} = false switches off `${path}`, the file that carries it"
    else if replaced entry
    then "${option replaced ["content"]} replaces `${path}`, the file that carries it, with its own bytes"
    else null;
  offMessage = unit: path: remedy:
    message unit (dropReason path)
    + ". Remove that override, or withhold it from ${runtime} with ${remedy}.";
  contextUnits = lib.optionals hasContext (
    lib.optional (aiCommon.hasContent (config.ai.context or null)) ["ai" "context"]
    ++ lib.optional (aiCommon.hasContent (poolValue "context")) (poolPath "context")
  );
  contextWarnings = let
    path = contentTargets.context or null;
  in
    lib.optionals (path != null && dropReason path != null)
    (map (unit: offMessage unit path "${lib.showOption (["ai" runtime] ++ namespaces.pool appRecord "context" ++ ["normalized" "context"])} = lib.mkForce null") contextUnits);
  offRuleWarnings = lib.concatLists (lib.mapAttrsToList (name: path: let
    unit =
      if lib.defaultTo {} (poolValue "rules") ? ${name}
      then poolPath "rules" ++ [name]
      else ["ai" "rules" name];
  in
    lib.optional (dropReason path != null)
    (offMessage unit path "${lib.showOption (poolPath "rules" ++ [name "enable"])} = false"))
  (contentTargets.rules or {}));
in
  if !cfg.enable
  then []
  else
    lib.unique
    (decomposition.warnings ++ rowWarnings ++ mcpWarnings ++ contextWarnings ++ offRuleWarnings)

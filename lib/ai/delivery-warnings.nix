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
  # Path each context/rule unit lands in (the record's `contentTargets`), the
  # paths the shared AGENTS.md owner holds, and whether the runtime has
  # context at all. All empty for a caller that knows none of them.
  contentTargets ? {},
  sharedTargets ? [],
  hasContext ? false,
  # Per staged path, the content `ai.<runtime>._generatedFiles` gives layer 1,
  # and whether its final layer-1 content replaced it.
  generatedContent ? {},
  generatedReplaced ? _path: false,
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
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
  present = path: value: let
    surface = lib.last path;
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
      && present path (get path)) (row.inputOptions or [])))
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
    then lib.findFirst overrides null (lib.sort lib.lessThan candidates)
    else runtime;
  # A staged path is carried by its final layer-1 entry: switched off by its
  # `enable`, replaced when its winning content is not the generated one. A
  # consumer value leaf merges with the generated document; it never replaces it.
  generatedDropReason = path: let
    shared = builtins.elem path sharedTargets;
    entry =
      if shared
      then config.ai.files.${path}
      else cfg.files.${path};
    contentReplaced =
      if shared
      then entry._contentPrio < (lib.mkDefault null).priority
      else generatedReplaced path;
    owner = overridingRuntime (candidate:
      if !entry.enable
      then !candidate.enable
      else candidate._contentPrio == entry._contentPrio)
    path;
    option = suffix: lib.showOption (["ai"] ++ lib.optional (owner != null) owner ++ ["files" path] ++ suffix);
  in
    if !entry.enable
    then "${option ["enable"]} = false switches off `${path}`, the file that carries it"
    else if contentReplaced
    then "${option ["content"]} replaces `${path}`, the file that carries it, with its own bytes"
    else null;
  # Only requested units backed by a generated or shared entry can be dropped.
  dropReason = path:
    if builtins.elem path sharedTargets || generatedContent ? ${path}
    then generatedDropReason path
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

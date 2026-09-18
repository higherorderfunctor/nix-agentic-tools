# Diagnostics are separate from lowering: warnings must neither change pool
# precedence nor force source-backed content discarded by final-file overrides.
{lib}: {
  appRecord,
  backend,
  config,
  options ? {},
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  runtime = appRecord.name;
  cfg = config.ai.${runtime};
  supports = pool: builtins.elem pool (appRecord.supportedPools or []);
  get = path: lib.attrByPath (lib.splitString "." path) null config;
  live = pool: lib.filterAttrs (_: value: value != null) pool;
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
  keyed = ["agents" "environmentVariables" "lspServers" "mcpServers" "rules" "skills"];
  rootRemaining = surface:
    builtins.removeAttrs (live (config.ai.${surface} or {}))
    (
      if supports surface
      then builtins.attrNames (cfg.${surface} or {})
      else []
    );
  present = path: let
    parts = lib.splitString "." path;
    surface = lib.last parts;
    value = get path;
  in
    if builtins.elem surface keyed
    then
      (
        if builtins.length parts == 2
        then rootRemaining surface
        else
          live (
            if value == null
            then {}
            else value
          )
      )
      != {}
    else if surface == "context"
    then value != null && ((value.source or null) != null || (value.text or "") != null && (value.text or "") != "")
    else if path == "ai.hooks"
    then lib.any (blocks: lib.any (block: block.hooks != []) blocks) (builtins.attrValues value)
    else nonEmpty value;
  message = path: reason: "${path} is set but ${backend} does not deliver it to ${runtime} (reason: ${reason})";
  rowWarnings = lib.concatMap (row:
    lib.optionals (row.ecosystem
      == runtime
      && row.mode == backend
      && (row.primitive == "notApplicable" || row ? deliveryGap))
    (map (path: message path (row.deliveryGap or row.reason))
      (builtins.filter (path:
        present path
        && (!(row.warnOnlyExplicit or false)
          || (lib.attrByPath ((lib.splitString "." path) ++ ["highestPrio"]) 1500 options) < 1500)) (row.inputOptions or []))))
  (lib.concatMap policy.writersOf policy.rows);
  missingPools =
    builtins.filter (pool: !supports pool && present "ai.${pool}")
    (["shell"] ++ lib.optionals (runtime == "kiro") ["agents" "hooks"]);
  # Kiro's same-named native agents/hooks writers do not consume root pools.
  poolWarnings = map (pool:
    message "ai.${pool}"
    "${runtime} has no lossless translation for the shared ${pool} pool; native runtime options are independent.")
  missingPools;
  effortPath =
    if (cfg.settings.reasoningEffort or null) != null
    then "ai.${runtime}.settings.reasoningEffort"
    else "ai.settings.reasoningEffort";
  effortWarnings =
    lib.optional
    (!(builtins.elem runtime ["claude" "codex"]) && get effortPath != null)
    (message effortPath "No lossless native reasoning-effort translation exists for this runtime.");
  entries = pool:
    (lib.mapAttrsToList (name: value: {
      inherit name value;
      path = "ai.${pool}.${name}";
    }) (rootRemaining pool))
    ++ (lib.mapAttrsToList (name: value: {
        inherit name value;
        path = "ai.${runtime}.${pool}.${name}";
      })
      (
        if supports pool
        then live (cfg.${pool} or {})
        else {}
      ));
  fieldWarning = entry: field: reason:
    lib.optional (
      if builtins.elem field ["env" "headers"]
      then (entry.value.${field} or {}) != {}
      else nonEmpty (entry.value.${field} or null)
    ) (message "${entry.path}.${field}" reason);
  agentWarnings =
    lib.optionals (runtime == "codex") (lib.concatMap (entry:
        fieldWarning entry "tools" "Codex agents have no equivalent tool allowlist field.") (entries "agents"));
  lspWarnings =
    lib.optionals (runtime == "kiro") (lib.concatMap (entry:
        fieldWarning entry "extensions" "Kiro has no LSP extension-to-language mapping surface.") (entries "lspServers"));
  ruleWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (entry:
    lib.optional ((entry.value.inclusion or null) == "manual")
    (message "${entry.path}.inclusion" "Kiro CLI does not load manual steering; this mode only works in IDE clients.")) (entries "rules"));
  hookWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (name: let
    hook = cfg.hooks.${name};
    ignored =
      if hook.action.type == "agent"
      then ["command"]
      else ["prompt"];
  in
    lib.optionals (hook.enabled != false) (
      lib.optional (hook.action.type == "agent" && hook.timeout != null)
      (message "ai.kiro.hooks.${name}.timeout" "Agent hook actions have no subprocess timeout.")
      ++ lib.concatMap (field:
        lib.optional (nonEmpty hook.action.${field})
        (message "ai.kiro.hooks.${name}.action.${field}" "The selected action.type uses the other action payload."))
      ignored
    )) (builtins.attrNames cfg.hooks));
  darwinTrustWarnings = lib.optional (runtime
    == "kiro"
    && (appRecord.pkgs.stdenv.hostPlatform.isDarwin or false)
    && !cfg.v3
    && cfg.trustedMcpTools != [])
  (message "ai.kiro.trustedMcpTools" "On Darwin the v2 launcher bypasses the chat wrapper; use kiro-cli-chat directly for this grant.");
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
  claudeWarnings = lib.optionals (runtime == "claude" && backend == "devenv") (
    lib.optional (nonEmpty (cfg.nativeSettings.mcpServers or null))
    (message "ai.claude.nativeSettings.mcpServers" "MCP belongs under ai.claude.mcpServers; this key is removed from settings.json.")
    ++ lib.optional ((cfg.agentsDir or null) != null && (import ./dir-helpers.nix {inherit lib;}).agentsFromDir cfg.agentsDir != {})
    (message "ai.claude.agentsDir" policy.definitions.agents.claude.devenv.reason)
    ++ lib.concatMap (surface:
      lib.optional (nonEmpty (cfg.${surface} or {}))
      (message "ai.claude.${surface}" "The devenv backend has no writer for this Claude surface."))
    ["marketplaces" "outputStyles" "plugins"]
  );
in
  if !cfg.enable
  then []
  else
    lib.unique
    (rowWarnings ++ poolWarnings ++ effortWarnings ++ agentWarnings ++ lspWarnings ++ ruleWarnings ++ hookWarnings ++ darwinTrustWarnings ++ mcpWarnings ++ claudeWarnings)

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
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  runtime = appRecord.name;
  cfg = config.ai.${runtime};
  supports = pool: builtins.elem pool (appRecord.supportedPools or []);
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
  keyed = ["agents" "environmentVariables" "lspServers" "mcpServers" "rules" "skills"];
  rootRemaining = surface:
    builtins.removeAttrs (live surface (config.ai.${surface} or {}))
    (
      if supports surface
      then builtins.attrNames (cfg.${surface} or {})
      else []
    );
  present = path: let
    surface = lib.last path;
    value = get path;
  in
    # A bare root pool is a FAN-OUT request whose documented behavior is to
    # degrade for a runtime that cannot consume it. There is no per-runtime
    # option to tombstone it with — declaring one for an unsupported pool is an
    # unknown-option error by design — so a warning here has no consumer remedy
    # and would repeat on every activation forever. The exclusion is recorded in
    # this policy's row and in the pool's own option description. A per-runtime
    # path always reports: that one the consumer wrote directly and can delete.
    if builtins.length path == 2 && !supports surface
    then false
    else if builtins.elem surface keyed
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
    then value != null && ((value.source or null) != null || (value.text or "") != null && (value.text or "") != "")
    else if path == ["ai" "hooks"]
    # `value` is null whenever the shared pool is not declared in this
    # composition at all, the same case the keyed and context arms guard.
    then value != null && lib.any (blocks: lib.any (block: block.hooks != []) blocks) (builtins.attrValues value)
    else nonEmpty value;
  message = path: reason: "${lib.showOption path} is set but ${backend} does not deliver it to ${runtime} (reason: ${reason})";
  rowWarnings = lib.concatMap (row:
    lib.optionals (row.ecosystem
      == runtime
      && row.mode == backend
      && (row.primitive == "notApplicable" || row ? deliveryGap))
    (map (path: message path (row.deliveryGap or row.reason))
      (builtins.filter (path:
        present path
        && (!(row.warnOnlyExplicit or false)
          || (lib.attrByPath (path ++ ["highestPrio"]) 1500 options) < 1500)) (row.inputOptions or []))))
  (lib.concatMap policy.writersOf policy.rows);
  effortPath =
    if (cfg.settings.reasoningEffort or null) != null
    then ["ai" runtime "settings" "reasoningEffort"]
    else ["ai" "settings" "reasoningEffort"];
  effortWarnings =
    lib.optional
    (!(builtins.elem runtime ["claude" "codex"]) && get effortPath != null)
    (message effortPath "No lossless native reasoning-effort translation exists for this runtime.");
  entries = pool:
    (lib.mapAttrsToList (name: value: {
      inherit name value;
      path = ["ai" pool name];
    }) (rootRemaining pool))
    ++ (lib.mapAttrsToList (name: value: {
        inherit name value;
        path = ["ai" runtime pool name];
      })
      (
        if supports pool
        then live pool (cfg.${pool} or {})
        else {}
      ));
  fieldWarning = entry: field: reason:
    lib.optional (
      if builtins.elem field ["env" "headers"]
      then (entry.value.${field} or {}) != {}
      else nonEmpty (entry.value.${field} or null)
    ) (message (entry.path ++ [field]) reason);
  agentWarnings =
    lib.optionals (runtime == "codex") (lib.concatMap (entry:
        fieldWarning entry "tools" "Codex agents have no equivalent tool allowlist field.") (entries "agents"));
  lspWarnings =
    lib.optionals (runtime == "kiro") (lib.concatMap (entry:
        fieldWarning entry "extensions" "Kiro has no LSP extension-to-language mapping surface.") (entries "lspServers"));
  ruleWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (entry:
    lib.optional ((entry.value.inclusion or null) == "manual")
    (message (entry.path ++ ["inclusion"]) "Kiro CLI does not load manual steering; this mode only works in IDE clients.")) (entries "rules"));
  hookWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (name: let
    hook = cfg.hooks.${name};
    ignored =
      if hook.action.type == "agent"
      then ["command"]
      else ["prompt"];
  in
    lib.optionals (hook.enabled != false) (
      lib.optional (hook.action.type == "agent" && hook.timeout != null)
      (message ["ai" "kiro" "hooks" name "timeout"] "Agent hook actions have no subprocess timeout.")
      ++ lib.concatMap (field:
        lib.optional (nonEmpty hook.action.${field})
        (message ["ai" "kiro" "hooks" name "action" field] "The selected action.type uses the other action payload."))
      ignored
    )) (builtins.attrNames cfg.hooks));
  # `--trust-tools` reaches the chat binary on BOTH backends, so this is a
  # withhold test rather than a platform test. Two argv paths drop the flag:
  # Darwin's launcher resolves the chat binary by app-bundle discovery and never
  # runs the wrapper that appends it, and the `acp` subcommand rejects it under
  # the v3 engine (packages/kiro-cli/lib/wrapPackage.nix:194-256). Exactly one
  # composition recovers the grant declaratively — Home Manager with v3, where
  # mkPermissionRules also writes it into settings/permissions.yaml
  # (packages/kiro-cli/lib/mkKiro.nix:707-742) — so that is the only case
  # suppressed, and the devenv half that the wrapper's own comment says is not
  # recovered declaratively now reports instead of staying silent.
  trustToolsWarnings = lib.optional (runtime
    == "kiro"
    && cfg.trustedMcpTools != []
    && ((appRecord.pkgs.stdenv.hostPlatform.isDarwin or false) || cfg.v3)
    && !(cfg.v3 && backend == "hm"))
  (message ["ai" "kiro" "trustedMcpTools"] "Darwin's launcher resolves the chat binary by bundle discovery and the `acp` subcommand rejects --trust-tools under the v3 engine, so the grant is withheld on those argv paths; only Home Manager with ai.kiro.v3 recovers it declaratively through settings/permissions.yaml.");
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
    lib.optional (nonEmpty (cfg.native.settings.mcpServers or null))
    (message ["ai" "claude" "native" "settings" "mcpServers"] "MCP belongs under ai.claude.mcpServers; this key is removed from settings.json.")
    ++ lib.concatMap (surface:
      lib.optional (nonEmpty (cfg.${surface} or {}))
      (message ["ai" "claude" surface] "The devenv backend has no writer for this Claude surface."))
    ["marketplaces" "outputStyles" "plugins"]
  );
in
  if !cfg.enable
  then []
  else
    lib.unique
    (rowWarnings ++ effortWarnings ++ agentWarnings ++ lspWarnings ++ ruleWarnings ++ hookWarnings ++ trustToolsWarnings ++ mcpWarnings ++ claudeWarnings)

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
  keyed = policy.keyedSurfaces;
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
    # degrade for a runtime that cannot consume it. A root warning needs a
    # per-runtime remedy, or it repeats on every activation forever. Only a
    # keyed pool the runtime supports has one: `ai.<runtime>.<pool>.<name> =
    # null` tombstones that name, which is what `rootRemaining` subtracts. An
    # unsupported pool has no per-runtime option at all (declaring one is an
    # unknown-option error by design), and a non-keyed pool (`context`, `hooks`)
    # composes root and per-runtime values, so nothing per-runtime withdraws
    # the root one. Those exclusions are recorded in this policy's row and in
    # the pool's own option description instead. A per-runtime path always
    # reports: that one the consumer wrote directly and can delete.
    if builtins.length path == 2 && !(supports surface && builtins.elem surface keyed)
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
  # A normalized agent's `tools` names Claude/Copilot tools. A runtime with
  # another vocabulary does not lower it, so the guardrail it expresses is
  # lost unless restated natively; a native `tools` for the same agent is that
  # restatement and silences the warning.
  agentToolReasons = {
    codex = _: "Codex agents have no equivalent tool allowlist field.";
    kimchi = name: "Kimchi matches its own lowercase builtins, so the agent gets every tool. Set ${lib.showOption ["ai" "kimchi" "agents" name]} to native Kimchi Markdown with its own `tools:` line to apply the guardrail there.";
    kiro = name: "Kiro takes capability tags, not Claude/Copilot tool names. Set ${lib.showOption ["ai" "kiro" "native" "agents" name "tools"]} (capability tags) and permissions to apply the guardrail there.";
  };
  agentWarnings = lib.optionals (agentToolReasons ? ${runtime}) (lib.concatMap (entry:
    lib.optionals ((cfg.native.agents.${entry.name}.tools or null) == null)
    (fieldWarning entry "tools" (agentToolReasons.${runtime} entry.name))) (entries "agents"));
  ruleWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (entry:
    lib.optional (aiCommon.resolveInclusion {
        runtime = "kiro";
        inherit (entry) name;
        rule = entry.value;
      }
      == "manual")
    (message (entry.path ++ ["inclusion"]) "Kiro CLI does not load manual steering; this mode only works in IDE clients.")) (entries "rules"));
  hookWarnings = lib.optionals (runtime == "kiro") (lib.concatMap (name: let
    hook = cfg.hooks.${name};
    # The payload the selected action.type ignores, and whether it is set.
    # Unset prompts still carry record fields; inspect their content.
    ignored =
      if hook.action.type == "agent"
      then {command = nonEmpty hook.action.command;}
      else {prompt = aiCommon.hasContent hook.action.prompt;};
  in
    lib.optionals (hook.enabled != false) (
      lib.optional (hook.action.type == "agent" && hook.timeout != null)
      (message ["ai" "kiro" "hooks" name "timeout"] "Agent hook actions have no subprocess timeout.")
      ++ lib.concatLists (lib.mapAttrsToList (field: set:
        lib.optional set
        (message ["ai" "kiro" "hooks" name "action" field] "The selected action.type uses the other action payload."))
      ignored)
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
    && cfg.cli.trustedMcpTools != []
    && ((appRecord.pkgs.stdenv.hostPlatform.isDarwin or false) || cfg.cli.v3)
    && !(cfg.cli.v3 && backend == "hm"))
  (message ["ai" "kiro" "cli" "trustedMcpTools"] "Darwin's launcher resolves the chat binary by bundle discovery and the `acp` subcommand rejects --trust-tools under the v3 engine, so the grant is withheld on those argv paths; only Home Manager with ai.kiro.cli.v3 recovers it declaratively through settings/permissions.yaml.");
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
  # Copilot's devenv settings land in the repository settings file, whose
  # reach is narrower than the user file Home Manager writes. Copilot resolves
  # it against the git root of the directory it runs in, so a devenv root
  # below the git root writes a file Copilot never opens. And only the
  # interactive session reads a repository `effortLevel`; `-p`, `--acp` and
  # `--server` read effort from the user file alone (copilot-cli 1.0.88
  # app.js). Each warning names a per-runtime remedy: withhold the native
  # value with null.
  copilotRepositorySettings = lib.filterAttrs (_: value: value != null) (cfg.native.settings or {});
  gitRoot = get ["git" "root"];
  devenvRoot = get ["devenv" "root"];
  copilotWarnings = lib.optionals (runtime == "copilot" && backend == "devenv") (
    lib.optional (copilotRepositorySettings != {} && gitRoot != null && devenvRoot != null && gitRoot != devenvRoot)
    (message ["ai" "copilot" "native" "settings"] "Copilot reads .github/copilot/settings.json from the git root (${toString gitRoot}), but devenv writes it under the devenv root (${toString devenvRoot}). Run devenv from the git root, or set the keys, including a lowered effortLevel, to null.")
    ++ lib.optional (get effortPath != null && copilotRepositorySettings ? effortLevel)
    "${lib.showOption effortPath} reaches copilot through devenv in interactive sessions only (reason: devenv delivers it as the repository effortLevel, which copilot -p, --acp and --server ignore; they read effort from the user settings file). Set ai.copilot.native.settings.effortLevel = null to withhold it."
  );
  # Personal plugins are user-scope; a project has nowhere to put one.
  claudeWarnings =
    lib.optional (runtime == "claude" && backend == "devenv" && nonEmpty (cfg.plugins or {}))
    (message ["ai" "claude" "plugins"] "The devenv backend has no writer for this Claude surface.");
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
    ++ lib.optional (aiCommon.hasContent (cfg.context or null)) ["ai" runtime "context"]
  );
  contextWarnings = let
    path = contentTargets.context or null;
  in
    lib.optionals (path != null && dropReason path != null)
    (map (unit: offMessage unit path "${lib.showOption ["ai" runtime "normalized" "context"]} = lib.mkForce null") contextUnits);
  offRuleWarnings = lib.concatLists (lib.mapAttrsToList (name: path: let
    unit =
      if (cfg.rules or {}) ? ${name}
      then ["ai" runtime "rules" name]
      else ["ai" "rules" name];
  in
    lib.optional (dropReason path != null)
    (offMessage unit path "${lib.showOption ["ai" runtime "rules" name "enable"]} = false"))
  (contentTargets.rules or {}));
in
  if !cfg.enable
  then []
  else
    lib.unique
    (rowWarnings ++ agentWarnings ++ ruleWarnings ++ hookWarnings ++ trustToolsWarnings ++ mcpWarnings ++ claudeWarnings ++ copilotWarnings ++ contextWarnings ++ offRuleWarnings)

# Shared content generation logic for AI CLI modules.
# cspell:ignore highestPrio
#
# Consumed by:
# - packages/*/lib/mk*.nix (factory-built HM + devenv modules)
{lib}: let
  aiTypes = import ./types.nix {inherit lib;};
  fragments = import ../fragments.nix {inherit lib;};
  contentType = enableDefault:
    aiTypes.optionalTextSource {
      description = "Markdown content";
      inherit enableDefault;
    };
  contentUsesSource = aiTypes.textSourceUsesSource;
  hasContent = value:
    value
    != null
    && (value.enable or true)
    && (
      if contentUsesSource value
      then value.source != null
      else value.text != ""
    );
  mkContentModule = {
    defaultFilename ? null,
    enableDefault ? false,
  }: let
    baseType = contentType enableDefault;
  in
    if defaultFilename == null
    then baseType
    else
      aiTypes.extendSubmodule baseType {
        options.filename = lib.mkOption {
          type = lib.types.addCheck lib.types.str (value:
            value
            != ""
            && builtins.baseNameOf value == value
            && value != "."
            && value != "..");
          default = defaultFilename;
          description = "Filename for this runtime's single always-on context artifact.";
        };
      };

  inclusionKinds = ["always" "auto" "fileMatch" "manual"];
  inclusionSupport = {
    claude = {
      kinds = ["always" "fileMatch"];
      onDemandWithReferences = false;
    };
    codex = {
      kinds = ["always" "fileMatch"];
      onDemandWithReferences = true;
    };
    copilot = {
      kinds = ["always" "fileMatch"];
      onDemandWithReferences = false;
    };
    kimchi = {
      kinds = ["always" "fileMatch"];
      onDemandWithReferences = true;
    };
    kiro = {
      kinds = inclusionKinds;
      onDemandWithReferences = false;
    };
  };
  inclusionOption = lib.mkOption {
    type = lib.types.listOf (lib.types.enum inclusionKinds);
    default = [];
    example = ["auto" "fileMatch"];
    description = ''
      Priority-ordered rule triggers. Each runtime uses the first trigger it
      supports: Claude and Copilot support `always` and `fileMatch`; Kiro
      supports all four triggers; Codex and Kimchi support `always` and
      `fileMatch`, plus `auto` and `manual` when `references` is non-empty.
      `fileMatch` consumes `matcher`, and `auto` requires a non-empty
      `description` when selected.
      When omitted, the default is `["always"]` without a matcher and
      `["fileMatch"]` with one.
    '';
  };
  kiroInclusionOption = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum ["always" "auto" "fileMatch" "manual"]);
    default = null;
    example = "auto";
    description = ''
      Kiro-only scalar trigger override. When set on
      `ai.kiro.rules.<name>.inclusion`, it replaces the root rule's portable
      priority list for Kiro. null derives the portable default from
      `matcher`: `always` without a matcher and `fileMatch` with one. The Kiro
      pool keeps this established scalar spelling; root and other runtime pools
      use a priority-ordered list at the same option name.
    '';
  };
  matcherOption = lib.mkOption {
    # `nullOr` bypasses an element type's outer `addCheck` during nested
    # merging, so spell this as a real sum type to reject an empty list.
    type = lib.types.oneOf [
      (lib.types.enum [null])
      (lib.types.addCheck (lib.types.listOf lib.types.str) (value: value != []))
    ];
    default = null;
    description = ''
      File globs consumed when the resolved trigger is `fileMatch`. null means
      the rule has no file scope and defaults its trigger list to `["always"]`;
      a non-empty list defaults it to `["fileMatch"]`. Claude lowers the globs
      to `paths`, Copilot to `applyTo`, Kiro to `fileMatchPattern`, and Codex to
      a prose scope note or a compact index entry when `references` is non-empty.
    '';
  };
  referencesOption = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["docs/architecture/storage.md"];
    description = ''
      Project-relative paths of the documents that hold this rule's
      authoritative text. Runtimes with native path scoping (Claude, Copilot,
      Kiro) ignore it and deliver the body. A flat AGENTS.md renderer (Codex)
      lists a `fileMatch` rule that names references in a compact path-scoped
      index — its globs and links to these documents — instead of inlining its
      body into the always-loaded file. References also let Codex support
      `auto` and `manual` through an on-demand index entry. Paths resolve
      against the directory the runtime runs in, so on Home Manager, where
      AGENTS.md is user-global, they name files of whatever project is open.
    '';
  };
  mkRuleModule = {kiroNative ? false}:
    aiTypes.extendSubmodule (contentType true) ({config, ...}: {
      options = {
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Short description forwarded to runtime renderers.";
        };
        inclusion =
          if kiroNative
          then kiroInclusionOption
          else inclusionOption;
        matcher = matcherOption;
        references = referencesOption;
      };

      config = lib.optionalAttrs (!kiroNative) {
        inclusion = lib.mkDefault (
          if config.matcher == null
          then ["always"]
          else ["fileMatch"]
        );
      };
    });

  normalizeInclusion = rule:
    if builtins.isList rule.inclusion
    then rule.inclusion
    else if rule.inclusion != null
    then [rule.inclusion]
    else if rule.matcher == null
    then ["always"]
    else ["fileMatch"];

  resolveInclusion = {
    runtime,
    name,
    rule,
  }: let
    requested = normalizeInclusion rule;
    support = inclusionSupport.${runtime} or (throw "resolveInclusion: unknown runtime '${runtime}'");
    supported =
      support.kinds
      ++ lib.optionals (support.onDemandWithReferences && rule.references != []) ["auto" "manual"];
    selected = lib.findFirst (kind: builtins.elem kind supported) null requested;
    requestedJson = builtins.toJSON requested;
    supportedJson = builtins.toJSON supported;
  in
    if selected == null
    then throw "ai.rules.${name}: runtime '${runtime}' supports ${supportedJson}, but requested inclusion priority list ${requestedJson} has no supported trigger"
    else if selected == "auto" && rule.description == ""
    then throw "ai.rules.${name}: resolved inclusion 'auto' for runtime '${runtime}' requires a non-empty description"
    else if selected == "fileMatch" && rule.matcher == null
    then throw "ai.rules.${name}: resolved inclusion 'fileMatch' for runtime '${runtime}' requires a non-null matcher"
    else selected;
  # Flatten nested Nix attrsets into dot-notation keys for CLIs that
  # expect flat JSON (e.g., Kiro's cli.json uses `"chat.enableTangentMode"`
  # not `{"chat":{"enableTangentMode":...}}`). Supports grouping:
  #
  #   { mcp.loadedBefore = true; chat = { enableTangentMode = true; enableCheckpoint = true; }; }
  #   → { "mcp.loadedBefore" = true; "chat.enableTangentMode" = true; "chat.enableCheckpoint" = true; }
  #
  # Leaf values (non-attrset, or attrsets with `_type` like mkOption
  # results) are kept as-is. Only plain nested attrsets are flattened.
  #
  # `terminal` is the list of dotted paths that are complete SETTING KEYS, and
  # it exists because attrset shape alone cannot say where a key stops and its
  # value begins. A flat-dotted config format may still have object-valued
  # settings — kiro's `chat.modelDefaults` maps model ids to records — and
  # without a boundary the walk descends straight through the key and emits
  # `chat.modelDefaults.<model>.<field>`, which the CLI never matches. Recursion
  # stops as soon as the accumulated path is in `terminal`, so the rest of the
  # value survives as JSON.
  #
  # Pass `[]` for the historical flatten-everything behavior. There is no
  # `flattenDotKeys` alias for that: kiro is the only consumer of this format
  # and it always passes a boundary, so an alias would be dead code. The
  # boundary belongs to whichever runtime owns the format and is extracted from
  # its binary rather than curated — see `settingKeys` in
  # packages/kiro-cli/extracted/.
  flattenDotKeysUntil = terminal: let
    go = prefix: attrs:
      lib.foldlAttrs (acc: name: value: let
        key =
          if prefix == ""
          then name
          else "${prefix}.${name}";
      in
        if lib.isAttrs value && !(value ? _type) && !(builtins.elem key terminal)
        then acc // (go key value)
        else acc // {${key} = value;})
      {}
      attrs;
  in
    go "";
  readContent = value:
    if value == null
    then ""
    else value.text;
  # Each rule rendered through a runtime's transformer, with the rule's matcher
  # as its `paths` and its resolved text, keyed by the path `path` gives its
  # name. `context` is the transformer's render context for a rule name.
  renderRules = {
    context ? _: {},
    path,
    rules,
    runtime,
    transformer,
  }:
    lib.mapAttrs' (name: rule: let
      inclusion = resolveInclusion {inherit name rule runtime;};
    in
      lib.nameValuePair (path name) (fragments.mkRenderer transformer (context name) (rule
        // {
          inherit inclusion name;
          paths =
            if inclusion == "fileMatch"
            then rule.matcher
            else null;
          text = readContent rule;
        })))
    rules;
in {
  # ── Markdown content records ───────────────────────────────────────
  # Context and rules share one text-source record. The type resolves source
  # contents and higher-priority inline overrides into the effective `text`,
  # while `_sourceWins` lets file emission keep a source-only winner lazy.
  inherit flattenDotKeysUntil inclusionSupport normalizeInclusion resolveInclusion;

  optionalContentModule = mkContentModule {};
  runtimeContextModule = defaultFilename:
    mkContentModule {inherit defaultFilename;};

  inherit hasContent readContent;

  composeContent = values: let
    present = builtins.filter hasContent values;
  in
    if present == []
    then null
    else if builtins.length present == 1
    then builtins.head present
    else let
      bodies = map (value: value.text) present;
    in
      if bodies == []
      then null
      else {text = lib.concatStringsSep "\n\n" bodies;};

  # One generated file entry, with the generator's priority on the CONTENT
  # option alone. `filterOverrides` runs before a type merges, so a whole-entry
  # `mkDefault` is DISCARDED by any consumer definition at ordinary priority —
  # including one that only sets a sibling field like `method`, which then
  # survives with no bytes at all. Putting the priority one level down is what
  # makes "change how this lands, keep what is in it" expressible.
  #
  # Callers gate this on the STRUCTURAL `hasMergedContext`, so the entry shape
  # does not inspect rendered bytes. Everything that depends on the value sits
  # INSIDE `mkDefault`, where `filterOverrides` can drop a discarded source
  # unread. Generated content explicitly enables its shared text-source record.
  contentFileEntry = value: {
    content = lib.mkDefault (aiTypes.textSourceFile value
      // {
        _generated = true;
        _surface = "context";
        enable = true;
      });
    format = lib.mkDefault "markdown";
  };

  inherit renderRules;

  # One old-path file entry per rendered rule (`renderRules`); the generated
  # text is a default on `content`, and `fields` are the runtime's own ones
  # (writer, ledger, facts).
  mkRuleFiles = {fields ? {}, ...} @ args:
    lib.mapAttrs (_path: text:
      {
        content = lib.mkDefault {
          _generated = true;
          _surface = "rules";
          enable = true;
          inherit text;
        };
        format = lib.mkDefault "markdown";
      }
      // fields)
    (renderRules (builtins.removeAttrs args ["fields"]));

  # ── Activation flag scoping ────────────────────────────────────────
  # Wrap a home.activation body in a subshell so its `set`/`shopt` flags
  # cannot outlive it.
  #
  # home-manager concatenates every DAG entry into ONE script that it opens
  # with `set -eu` + `set -o pipefail`. Flags an entry turns on stay on for
  # every LATER entry — including home-manager's own checkLinkTargets,
  # writeBoundary and linkGeneration. `inherit_errexit` is the one that bites:
  # it changes whether a failing `$( )` aborts, so leaking it silently
  # re-specifies the failure semantics of code we do not own.
  #
  # Scoping rather than dropping the flags keeps our own bodies fully strict
  # while making the leak structurally impossible. Safe only for bodies with no
  # parent-shell effects (no export, no cd, no trap) — check before wrapping.
  #
  # Failure still propagates: a body ending in `false` makes the subshell exit
  # non-zero, which the caller's `set -e` sees exactly as before. Use `false`,
  # never `exit` — `exit` would truncate the whole concatenated activation
  # script rather than failing one entry.
  scopedActivation = body: ''
    (
    ${body}
    )
  '';

  # ── Rule submodule types ───────────────────────────────────────────
  # The portable record carries the priority-ordered inclusion list. Kiro's
  # per-runtime pool keeps its established scalar option as a native override;
  # the backend transform normalizes it to a one-item list after pool merging.
  ruleModule = mkRuleModule {};
  kiroRuleModule = mkRuleModule {kiroNative = true;};

  # ── Settings utilities ──────────────────────────────────────────────

  # Closed normalized settings shared by the root and every runtime whose
  # app record supports the `settings` pool (all but Kiro).
  # Native settings live in each factory's separate `native.settings` option.
  normalizedSettingsType = lib.types.submodule {
    options.reasoningEffort = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["high" "low" "medium" "xhigh"]);
      default = null;
      description = ''
        Portable reasoning effort across runtimes that persist the same
        semantic values. Runtime-specific values belong in
        `ai.<runtime>.native.settings`.
      '';
    };
  };

  # Recursively filter null values from an attrset (for typed settings
  # with freeformType where defaults are null). Also removes empty
  # sub-attrsets left after filtering.
  filterNulls = let
    go = attrs: let
      mapped = lib.mapAttrs (_: v:
        if lib.isAttrs v
        then go v
        else v)
      attrs;
    in
      lib.filterAttrs (_: v: v != null && v != {}) mapped;
  in
    go;

  # ── Dir option type ──────────────────────────────────────────
  # Shared option type for the L1/L2b Dir-shaped options on the
  # ai.* factory. Polymorphic `path | { path, filter? }` per plan
  # §3.5 and §4. `filter` is `name → bool` (name only, not the
  # full direntry attrs). Downstream normalization happens in
  # lib/ai/dir-helpers.nix via `resolveDirArg`.
  #
  # `filter` defaults to null, which each helper resolves to its own
  # default, so the submodule form filters like the bare-path form.
  dirOptionType = lib.types.either lib.types.path (lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.path;
        description = "Source directory.";
      };
      filter = lib.mkOption {
        type = lib.types.nullOr (lib.types.functionTo lib.types.bool);
        default = null;
        description = "Predicate `name → bool`. Entries for which this returns false are skipped. Null uses the consuming helper's default: `.md` files for rules, the runtime's agent file suffixes for agents, every subdirectory for skills.";
      };
    };
  });

  # ── Scalar override resolution ──────────────────────────────────
  # DELIBERATELY different from keyed-pool merging below.
  #
  # So: a non-null per-CLI value wins, `null` inherits the root, and
  # `null` at both levels means "not configured" rather than "empty".
  # Kept as a named helper rather than an inline `if` at each call
  # site so the semantic is stated once and greps as a unit.
  resolveOverride = {
    topValue,
    cliValue,
  }:
    if cliValue != null
    then cliValue
    else topValue;

  # ── Keyed-pool override and negation ────────────────────────────
  # Per-runtime entries shallowly replace root entries at the same key.
  # A per-runtime null is a tombstone: filter it only after precedence is
  # resolved so it can suppress the inherited root entry. Values remain
  # atomic; records are never recursively merged across levels.
  mergePool = {
    topPool,
    cliPool,
  }:
    lib.filterAttrs (_name: value: value != null) (topPool // cliPool);
}

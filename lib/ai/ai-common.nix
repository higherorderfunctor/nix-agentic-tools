# Shared content generation logic for AI CLI modules.
#
# Consumed by:
# - packages/*/lib/mk*.nix (factory-built HM + devenv modules)
# - lib/hm-helpers.nix (filterNulls re-export)
{lib}: let
  contentOptions = {
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a Markdown source file. Mutually exclusive with `text`.";
    };
    text = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Inline Markdown content. Mutually exclusive with `source`.";
    };
  };
  hasContent = value:
    value
    != null
    && ((value.text or null) != null || (value.source or null) != null);
  contentFieldsAreValid = requireContent: value: let
    count =
      lib.count
      (field: (value.${field} or null) != null)
      ["source" "text"];
  in
    count <= 1 && (!requireContent || count == 1);
  validateContent = requireContent: value:
    if contentFieldsAreValid requireContent value
    then value
    else
      throw
      "Markdown content must set ${lib.optionalString (!requireContent) "at most "}one of `text` or `source`";
  ruleIsValid = contentFieldsAreValid true;
  mkContentModule = {defaultFilename ? null}:
    lib.types.submodule {
      options =
        contentOptions
        // lib.optionalAttrs (defaultFilename != null) {
          filename = lib.mkOption {
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
    };

  kiroInclusionOption = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum ["always" "auto" "fileMatch" "manual"]);
    default = null;
    example = "auto";
    description = ''
      Kiro steering inclusion mode. null preserves the portable default:
      `matcher = null` becomes `always`, while a matcher becomes `fileMatch`.
      `fileMatch` consumes `matcher`; `auto` requires a non-empty name and
      description. Other ecosystems continue translating `matcher` through
      their native scoping mechanism and intentionally ignore this Kiro-only
      override.
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
      File globs selecting where this rule applies. null means always-on.
      Runtimes translate the normalized matcher into their native scoping
      mechanism; flat AGENTS.md consumers preserve it as a prose scope note.
    '';
  };
  mkRuleModule = {kiroNative ? false}:
    lib.types.submodule {
      options =
        contentOptions
        // {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Short description forwarded to runtime renderers.";
          };
          matcher = matcherOption;
        }
        // lib.optionalAttrs kiroNative {
          inclusion = kiroInclusionOption;
        };
    };
in {
  # ── Markdown content records ───────────────────────────────────────
  # Context and rules share one home.file-shaped content record. Keeping paths
  # as `source` data avoids writeText/IFD and preserves direct symlink emission
  # when a single source is not being concatenated with another contribution.
  contentModule = mkContentModule {};
  optionalContentModule = mkContentModule {};
  validateOptionalContent = validateContent false;
  validateRules = rules:
    lib.mapAttrs (name: rule:
      if rule == null || ruleIsValid rule
      then rule
      else
        throw
        "Rule `${name}` must set exactly one of `text` or `source`")
    rules;
  runtimeContextModule = defaultFilename:
    mkContentModule {inherit defaultFilename;};

  inherit hasContent;

  readContent = value:
    if value == null
    then ""
    else if (value.text or null) != null
    then value.text
    else if (value.source or null) != null
    then builtins.readFile value.source
    else "";

  composeContent = values: let
    present = builtins.filter (value:
      hasContent value
      && ((value.text or null) == null || value.text != ""))
    values;
  in
    if present == []
    then null
    else if builtins.length present == 1
    then let
      value = builtins.head present;
    in
      if (value.text or null) != null
      then {inherit (value) text;}
      else {inherit (value) source;}
    else let
      bodies = builtins.filter (body: body != "") (map (value:
        if (value.text or null) != null
        then value.text
        else builtins.readFile value.source)
      present);
    in
      if bodies == []
      then null
      else {text = lib.concatStringsSep "\n\n" bodies;};

  contentFileEntry = value:
    if value == null
    then null
    else if (value.source or null) != null
    then {inherit (value) source;}
    else {inherit (value) text;};

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

  # ── LSP server submodule type ──────────────────────────────────────
  # Typed LSP server definition. The ai.* module holds these; fanout
  # transforms to per-ecosystem JSON via mkLspConfig (Kiro base),
  # mkCopilotLspConfig (adds fileExtensions), mkClaudeLspConfig
  # (adds extensionToLanguage).
  #
  # Command resolution (exactly one of these two must be set):
  # - `package` (+ optional `binary` override) — renders as
  #   `${package}/bin/${binary}`. For LSPs with a nix package.
  # - `command` — used verbatim. For LSPs available on PATH (e.g.
  #   via devenv `packages = [pkgs.nixd];`) or external binaries
  #   without a nix package.
  lspServerModule = lib.types.submodule ({name, ...}: {
    options = {
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["--stdio"];
        description = "Arguments to pass to the LSP binary.";
      };
      binary = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Binary name within `package` (defaults to attribute name). Ignored when `command` is set.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Literal command (absolute path or PATH-resolvable). Alternative to `package`+`binary`.";
        example = "nixd";
      };
      extensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "File extensions this server handles (without leading dots). Used by Copilot/Claude to build ext→language mappings; ignored by Kiro.";
        example = ["nix"];
      };
      initializationOptions = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "LSP initialization options passed during handshake.";
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "LSP server nix package. Alternative to `command`.";
      };
    };
  });

  # ── LSP config transforms ─────────────────────────────────────────
  # Transform a typed LSP server to the JSON format expected by CLIs.
  # Helpers are inlined below rather than broken out as separate
  # attrset members because the attrset can't reference its own
  # members without a let-wrap around the whole module output.

  # Base format (Kiro): { command, args, ?initializationOptions }.
  # Command resolution: prefer explicit `command`, else
  # `${package}/bin/${binary}`, else throw. Kiro does not consume
  # `extensions` — it has no extension→language mapping surface;
  # editor plugins handle that separately.
  mkLspConfig = name: server:
    {
      command =
        if server.command != null
        then server.command
        else if server.package != null
        then "${server.package}/bin/${server.binary}"
        else throw "ai.lspServers.${name}: must set one of `command` or `package`";
      inherit (server) args;
    }
    // lib.optionalAttrs (server.initializationOptions != {}) {
      inherit (server) initializationOptions;
    };

  # Copilot adds `fileExtensions` mapping: `{ ".ext" = <serverName>; }`.
  mkCopilotLspConfig = name: server: let
    base = {
      command =
        if server.command != null
        then server.command
        else if server.package != null
        then "${server.package}/bin/${server.binary}"
        else throw "ai.lspServers.${name}: must set one of `command` or `package`";
      inherit (server) args;
    };
  in
    base
    // lib.optionalAttrs (server.extensions != []) {
      fileExtensions = lib.listToAttrs (map (ext: {
          name = ".${ext}";
          value = name;
        })
        server.extensions);
    }
    // lib.optionalAttrs (server.initializationOptions != {}) {
      inherit (server) initializationOptions;
    };

  # Claude adds `extensionToLanguage` mapping. Same structure as
  # Copilot's fileExtensions; different key name per upstream docs
  # for `programs.claude-code.lspServers.<name>`.
  mkClaudeLspConfig = name: server: let
    base = {
      command =
        if server.command != null
        then server.command
        else if server.package != null
        then "${server.package}/bin/${server.binary}"
        else throw "ai.lspServers.${name}: must set one of `command` or `package`";
      inherit (server) args;
    };
  in
    base
    // lib.optionalAttrs (server.extensions != []) {
      extensionToLanguage = lib.listToAttrs (map (ext: {
          name = ".${ext}";
          value = name;
        })
        server.extensions);
    }
    // lib.optionalAttrs (server.initializationOptions != {}) {
      inherit (server) initializationOptions;
    };

  # ── Rule submodule types ───────────────────────────────────────────
  # The portable record stays closed around normalized content + matcher.
  # Kiro's per-runtime pool extends it with its native inclusion modes; those
  # modes are intentionally unavailable at the root and on other runtimes.
  ruleModule = mkRuleModule {};
  kiroRuleModule = mkRuleModule {kiroNative = true;};

  # ── MCP server transform ───────────────────────────────────────────
  # Transform a typed MCP server submodule value into the JSON structure
  # expected by target ecosystems (VS Code mcp.json / Kiro mcp.json).
  transformMcpServer = server:
    if server.type == "stdio"
    then
      {
        type = "stdio";
        inherit (server) command;
      }
      // lib.optionalAttrs (server.args != []) {inherit (server) args;}
      // lib.optionalAttrs (server.env != {}) {inherit (server) env;}
    else if server.type == "http"
    then {
      type = "http";
      inherit (server) url;
    }
    else throw "Invalid MCP server type: ${server.type}";

  # ── Settings utilities ──────────────────────────────────────────────

  # Closed normalized settings shared by the root and every runtime scope.
  # Native settings live in each factory's separate `nativeSettings` option.
  normalizedSettingsType = lib.types.submodule {
    options.reasoningEffort = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["high" "low" "medium" "xhigh"]);
      default = null;
      description = ''
        Portable reasoning effort across runtimes that persist the same
        semantic values. Runtime-specific values belong in
        `ai.<runtime>.nativeSettings`.
      '';
    };
  };

  # Flatten nested Nix attrsets into dot-notation keys for CLIs that
  # expect flat JSON (e.g., Kiro's cli.json uses `"chat.enableTangentMode"`
  # not `{"chat":{"enableTangentMode":...}}`). Supports grouping:
  #
  #   { mcp.loadedBefore = true; chat = { enableTangentMode = true; enableCheckpoint = true; }; }
  #   → { "mcp.loadedBefore" = true; "chat.enableTangentMode" = true; "chat.enableCheckpoint" = true; }
  #
  # Leaf values (non-attrset, or attrsets with `_type` like mkOption
  # results) are kept as-is. Only plain nested attrsets are flattened.
  flattenDotKeys = let
    go = prefix: attrs:
      lib.foldlAttrs (acc: name: value: let
        key =
          if prefix == ""
          then name
          else "${prefix}.${name}";
      in
        if lib.isAttrs value && !(value ? _type)
        then acc // (go key value)
        else acc // {${key} = value;})
      {}
      attrs;
  in
    go "";

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
  # The default filter here keeps `.md` files — it's the common
  # case for rules/agents. Helpers that want different defaults
  # (skills: always-true, hooks: always-true) override the filter
  # at their call site; the option's default text is cosmetic.
  dirOptionType = lib.types.either lib.types.path (lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.path;
        description = "Source directory.";
      };
      filter = lib.mkOption {
        type = lib.types.functionTo lib.types.bool;
        default = name: lib.hasSuffix ".md" name;
        defaultText = lib.literalExpression "name: lib.hasSuffix \".md\" name";
        description = "Predicate `name → bool`. Entries for which this returns false are skipped.";
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

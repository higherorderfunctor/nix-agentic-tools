# Shared content generation logic for AI CLI modules.
# cspell:ignore highestPrio
#
# Consumed by:
# - packages/*/lib/mk*.nix (factory-built HM + devenv modules)
# - lib/hm-helpers.nix (filterNulls re-export)
{lib}: let
  aiTypes = import ./types.nix {inherit lib;};
  contentType = enableDefault:
    aiTypes.extendSubmodule
    (aiTypes.optionalTextSource {
      description = "Markdown content";
      inherit enableDefault;
    })
    ({
      config,
      options,
      ...
    }: {
      options._sourceWins = lib.mkOption {
        type = lib.types.bool;
        default =
          config.source
          != null
          && options.source.highestPrio < options.text.highestPrio;
        description = "Whether source supplies the effective Markdown content.";
        internal = true;
        readOnly = true;
      };
    });
  contentUsesSource = value:
    value._sourceWins or (!(value ? text) && (value.source or null) != null);
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
    aiTypes.extendSubmodule (contentType true) {
      options =
        {
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
  # packages/kiro-cli/extracted.json.
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
  # ── LSP helpers ────────────────────────────────────────────────────
  # Command resolution: prefer explicit `command`, else
  # `${package}/bin/${binary}`, else throw.
  lspCommand = name: server:
    if server.command != null
    then server.command
    else if server.package != null
    then "${server.package}/bin/${server.binary}"
    else throw "ai.lspServers.${name}: must set one of `command` or `package`";
  # A server's `extensions`, for a runtime that routes files to servers by
  # extension alone (Copilot, Kiro). With none, the entry would handle no
  # file at all, and Copilot rejects the whole file besides, so this throws
  # rather than render a server that silently never starts.
  lspRequiredExtensions = runtime: name: server:
    if server.extensions != []
    then server.extensions
    else throw "ai.lspServers.${name}: ${runtime} routes files to LSP servers by extension, so `extensions` must name at least one; set it, or drop the server for ${runtime} with `ai.${runtime}.lspServers.${name} = null`";
  # `{ ".<ext>" = <server attribute name>; }` for Copilot and Claude.
  lspExtensionMap = name: extensions:
    lib.listToAttrs (map (ext: {
        name = ".${ext}";
        value = name;
      })
      extensions);
in {
  # ── Markdown content records ───────────────────────────────────────
  # Context and rules share one text-source record. The type resolves source
  # contents and higher-priority inline overrides into the effective `text`,
  # while `_sourceWins` lets file emission keep a source-only winner lazy.
  inherit flattenDotKeysUntil;

  contentModule = mkContentModule {};
  optionalContentModule = mkContentModule {};
  runtimeContextModule = defaultFilename:
    mkContentModule {inherit defaultFilename;};

  inherit hasContent;

  readContent = value:
    if value == null
    then ""
    else value.text;

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

  contentFileEntry = value:
    if value == null
    then null
    else if contentUsesSource value
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
  # transforms to per-ecosystem JSON via mkKiroLspFile, mkCopilotLspFile
  # (both whole files) and mkClaudeLspConfig (one entry).
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
        description = "File extensions this server handles (without leading dots). Kiro emits them as `file_extensions`; Copilot and Claude map each to the server name. Copilot and Kiro route files to servers by extension alone, so a server they receive must name at least one (evaluation throws otherwise).";
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
  # Each ecosystem gets a producer for its WHOLE lsp file, not one entry,
  # because both Copilot and Kiro reject a bare per-server map: the
  # envelope key is part of the file format, so it belongs with the
  # producer rather than with each writer.

  # Kiro: `.kiro/settings/lsp.json` = `{ languages.<id> = { … }; }` with
  # snake_case fields, per https://kiro.dev/docs/tools/code-intelligence/
  # and the default table embedded in kiro-cli 2.22.1. The docs mark only
  # `file_patterns`, `multi_workspace` and `request_timeout_secs` as
  # optional, so every other documented field is always emitted.
  # `project_patterns` and `exclude_patterns` have no `lspServerModule`
  # option and are emitted empty. Kiro's `<id>` key is a language, which the
  # server's attribute name stands in for, as it does for Copilot below.
  mkKiroLspFile = servers: {
    languages =
      lib.mapAttrs (name: server: {
        inherit name;
        inherit (server) args;
        command = lspCommand name server;
        exclude_patterns = [];
        file_extensions = lspRequiredExtensions "kiro" name server;
        initialization_options = server.initializationOptions;
        project_patterns = [];
      })
      servers;
  };

  # Copilot: `~/.copilot/lsp-config.json` (user) and `.github/lsp.json`
  # (repository) are both `{ lspServers.<name> = { … }; }`. copilot-cli
  # 1.0.88's validator marks `fileExtensions` Required, so a server with no
  # `extensions` throws instead of producing a file Copilot rejects whole.
  # Upstream maps each extension to a LANGUAGE id (".ts" = "typescript");
  # `lspServerModule` has no language-id option, so the server's attribute
  # name stands in, which matches only when the server is named after its
  # language.
  mkCopilotLspFile = servers: {
    lspServers = lib.mapAttrs (name: server:
      {
        command = lspCommand name server;
        inherit (server) args;
        fileExtensions = lspExtensionMap name (lspRequiredExtensions "copilot" name server);
      }
      // lib.optionalAttrs (server.initializationOptions != {}) {
        inherit (server) initializationOptions;
      })
    servers;
  };

  # Claude: one `programs.claude-code.lspServers.<name>` entry, with an
  # `extensionToLanguage` mapping of the same shape as Copilot's.
  mkClaudeLspConfig = name: server:
    {
      command = lspCommand name server;
      inherit (server) args;
    }
    // lib.optionalAttrs (server.extensions != []) {
      extensionToLanguage = lspExtensionMap name server.extensions;
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

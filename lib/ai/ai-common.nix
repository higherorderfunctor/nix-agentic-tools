# Shared content generation logic for AI CLI modules.
#
# Consumed by:
# - packages/*/lib/mk*.nix (factory-built HM + devenv modules)
# - lib/hm-helpers.nix (filterNulls re-export)
{lib}: {
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

  # ── Instruction submodule type ──────────────────────────────────────
  # Shared semantic fields, translated per ecosystem by frontmatter generators.
  instructionModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description (used by Claude and Kiro frontmatter).";
      };
      paths = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          File path globs this instruction applies to. null = always loaded.
          Translated per ecosystem:
          - Claude: paths: frontmatter
          - Kiro: inclusion: fileMatch + fileMatchPattern:
          - Copilot: applyTo: glob
        '';
      };
      text = lib.mkOption {
        type = lib.types.lines;
        description = "Instruction body (markdown).";
      };
    };
  };

  # ── Rule submodule type ────────────────────────────────────────────
  # Attrs-shaped analog of instructionModule. Each entry becomes one file
  # in the per-ecosystem rules directory (.claude/rules/<name>.md,
  # .kiro/steering/<name>.md, .github/instructions/<name>.instructions.md).
  # The attribute name becomes the filename stem. `text` accepts either
  # inline markdown lines or a path to a file.
  #
  # Graduated shape replacing the list-of-attrs `instructions` pattern —
  # attrs let per-CLI overrides win on name collision and produce
  # deterministic ordering. List shape is kept for back-compat; rules
  # and instructions coexist in the factory emission.
  ruleModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description (used by Claude and Kiro frontmatter).";
      };
      paths = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          File path globs this rule applies to. null = always loaded.
          Translated per ecosystem:
          - Claude: paths: frontmatter
          - Kiro: inclusion: fileMatch + fileMatchPattern:
          - Copilot: applyTo: glob
        '';
      };
      text = lib.mkOption {
        type = lib.types.either lib.types.lines lib.types.path;
        description = ''
          Rule body (inline markdown or Nix path to a `.md` file).
          Content is baked into the nix store at eval time; transformer
          frontmatter IS injected on emission.
        '';
      };
    };
  };

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

  # ── Collision-as-failure pool merge ─────────────────────────────
  # Merge two attrset pools and surface duplicate keys as NixOS
  # module assertions. The shared `ai.*` pools (rules, skills,
  # context, mcpServers, lspServers, environmentVariables, agents)
  # fan out to every enabled CLI, and each CLI may also contribute
  # per-CLI entries via `ai.<cli>.<pool>`. Silent `//` merges at
  # that boundary let a later contributor override an earlier one
  # without a signal; the user directive is "collisions are
  # failure, we don't merge over keys".
  #
  # Inputs:
  #   poolName : human-readable label for the pool, used in the
  #              assertion message (e.g. "rule", "skill",
  #              "MCP server", "LSP server", "agent",
  #              "environment variable").
  #   cliName  : CLI identifier for error context (e.g. "claude").
  #              Use `null` for boundaries that aren't per-CLI.
  #   topPool  : attrset of entries contributed at top level
  #              (`ai.<pool>`).
  #   cliPool  : attrset of entries contributed per-CLI
  #              (`ai.<cli>.<pool>`).
  #
  # Output: an attrset with
  #   - `merged`     : the combined pool (safe to read even when
  #                    collisions exist — per-CLI values win, same
  #                    as the legacy `//` shape, so downstream
  #                    references still resolve until `assertions`
  #                    fire and abort eval).
  #   - `assertions` : a list of NixOS assertion attrs naming each
  #                    duplicate key and the two contributing pools.
  mergeWithCollisionCheck = {
    poolName,
    cliName ? null,
    topPool,
    cliPool,
  }: let
    duplicates = lib.attrNames (builtins.intersectAttrs topPool cliPool);
    scope =
      if cliName == null
      then "ai.${poolName}"
      else "ai.${cliName}.${poolName}";
    mkAssertion = key: {
      assertion = false;
      message =
        "${poolName} '${key}' declared in both ai.${poolName} and "
        + "${scope} — collisions across shared ai.* pools are errors. "
        + "Rename one or delete the duplicate.";
    };
  in {
    merged = topPool // cliPool;
    assertions = map mkAssertion duplicates;
  };
}

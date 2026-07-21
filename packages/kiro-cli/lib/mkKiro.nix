# Kiro-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kiro AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Fanout absorbed in Task 5 (A4): settings/cli.json activation merge,
# settings/mcp.json static write, settings/lsp.json write,
# per-instruction steering files under `.kiro/steering/`, skills
# routing to `.kiro/skills/`, agents + agentsDir writing under
# `.kiro/agents/`, hooks + hooksDir writing under `.kiro/hooks/`,
# environmentVariables fed into the HM symlinkJoin wrapper (export)
# and the devenv `env` blob.
#
# Source material: modules/kiro-cli/default.nix (291 lines, legacy
# HM module) + modules/devenv/kiro.nix (153 lines, legacy devenv).
{
  lib,
  pkgs,
  ...
}: let
  # Eval-pure read of the committed source list (no IFD).
  knownKiroModels = builtins.fromJSON (builtins.readFile ../models.json);

  # Eval-pure read of the committed hook-trigger sidecar (no IFD) — the source of
  # the `trigger` soft-enum. Regenerated on bump + drift-checked
  # (checks/kiro-cli-extracted.nix). See overlays.md § IFD Patterns.
  kiroExtracted =
    builtins.fromJSON (builtins.readFile ../../../overlays/kiro-cli-extracted.json);

  # Typed hook wiring (northbound), mirroring the Claude slice. S1: an
  # `action.command` accepts a package, coerced to its executable path so
  # supporting files ride the /nix/store closure at absolute, cwd-independent
  # paths (Kiro runs hooks with cwd = project root). meta.mainProgram → getExe; a
  # bare-file derivation → its outPath; a string passes through.
  pkgToCommand = p:
    if lib.isDerivation p && (p.meta.mainProgram or null) != null
    then lib.getExe p
    else "${p}";

  # A hook action: `command` (subprocess) or `agent` (inline prompt appended to
  # the model context). `command` is S1 store-backed; extra fields round-trip via
  # the freeform JSON tail.
  kiroAction = lib.types.submodule {
    freeformType = (pkgs.formats.json {}).type;
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["command" "agent"];
        default = "command";
        description = "`command` runs a subprocess; `agent` appends `prompt` to the model context (no subprocess, ignores timeout).";
      };
      command = lib.mkOption {
        type = lib.types.nullOr (lib.types.coercedTo lib.types.package pkgToCommand lib.types.str);
        default = null;
        description = "For type=command: a package (coerced to its getExe path — companion files ride the store closure) or a string.";
      };
      prompt = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "For type=agent: the prompt appended to the current model context.";
      };
    };
  };

  # A single v3 hook record (keyed by hook name in `ai.kiro.hooks`). Un-modeled
  # fields round-trip via the freeform JSON tail.
  kiroHookRecord = lib.types.submodule {
    freeformType = (pkgs.formats.json {}).type;
    options = {
      trigger = lib.mkOption {
        type = lib.types.either (lib.types.enum kiroExtracted.hookTriggers) lib.types.str;
        description = "Lifecycle trigger — soft enum from the drift-checked sidecar (any string accepted for forward-compat).";
      };
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tool-name matcher (Pre/PostToolUse); null for triggers that take none.";
      };
      action = lib.mkOption {
        type = kiroAction;
        default = {};
        description = "What the hook does when it fires.";
      };
      timeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Timeout in seconds (Kiro default 60; 0 disables; ignored for `agent` actions).";
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether the hook is enabled (Kiro default true).";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Human-readable description.";
      };
      # Co-location key (Nix-side only; stripped before emission — NOT a Kiro
      # hook field). Records sharing a `file` are written together into one
      # `<configDir>/hooks/<file>.json` `{version,hooks:[…]}` envelope — the
      # typed path to N-hooks-in-one-file that the raw `hooksJson` escape hatch
      # gives (e.g. autoMemory's four hooks in kiro-memory.json). null → the
      # record's own attr name (one file per record; the back-compat default).
      file = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Co-location key: records sharing a `file` are written into one
          `<configDir>/hooks/<file>.json` envelope (multiple hooks per file).
          Defaults to the record's attribute name (one file per record). A
          Nix-side grouping key only — stripped from the emitted JSON.
        '';
      };
    };
  };

  # Render one typed record → its v3 hook object (an element of an envelope's
  # `hooks` list). `name` = the attr key; null optionals dropped (record +
  # action). `file` is the Nix-only co-location key — stripped, not a Kiro field.
  kiroHookObject = name: record:
    {inherit name;}
    // lib.filterAttrs (_: v: v != null) (removeAttrs record ["action" "file"])
    // {action = lib.filterAttrs (_: v: v != null) record.action;};

  # Effective co-location file key for a record: explicit `file`, else its attr
  # name (→ one file per record, the back-compatible default).
  kiroHookFileKey = name: record:
    if record.file != null
    then record.file
    else name;

  # Lower ALL typed records → { <fileKey> → { version, hooks:[…] } }, grouping
  # records that share a fileKey into ONE envelope so N hooks can live in one
  # file (the typed path off the raw `hooksJson` escape hatch). Records within a
  # file are ordered by attr name (mapAttrsToList is sorted → deterministic).
  kiroTypedHookFiles = hooks:
    lib.mapAttrs
    (_fileKey: entries: {
      version = "v1";
      hooks = map (e: kiroHookObject e.name e.record) entries;
    })
    (lib.groupBy
      (e: kiroHookFileKey e.name e.record)
      (lib.mapAttrsToList (name: record: {inherit name record;}) hooks));

  # Combine raw `hooksJson` (verbatim escape hatch) + typed `hooks` (lowered +
  # grouped to envelope JSON) into one <file-key> → JSON-string attrset, consumed
  # by BOTH backends. Typed wins on a key collision. A raw `hooksJson` value may
  # be a PATH (read its contents) or a string; resolve to string CONTENT here so
  # both backends write the file body — devenv's `writeText` would otherwise embed
  # the path string, and HM's `mkSourceEntry` handles paths but resolving keeps
  # them identical.
  mkAllHookFiles = cfg:
    lib.mapAttrs (_: c:
      if builtins.isPath c
      then builtins.readFile c
      else c)
    cfg.hooksJson
    // lib.mapAttrs (_fileKey: envelope: builtins.toJSON envelope) (kiroTypedHookFiles cfg.hooks);

  # Hook names are attrset keys interpolated straight into activation-script
  # paths (`$HOOKS_DIR/<name>.json`) and shell heredocs, so a `/`, `..`,
  # whitespace, or quote would write outside the hooks dir or break the emitted
  # script. Require a leading alphanumeric then `[A-Za-z0-9._-]` (covers
  # kiro-memory, pre-commit, lint). Shared assertion for both backends.
  hookNameSafe = name: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
  hookNameAssertion = cfg: let
    bad =
      builtins.filter (n: !hookNameSafe n)
      (builtins.attrNames cfg.hooks ++ builtins.attrNames cfg.hooksJson);
  in {
    assertion = bad == [];
    message = "ai.kiro: hook names must match [A-Za-z0-9][A-Za-z0-9._-]* (no path separators, whitespace, or quotes); offending: ${lib.concatStringsSep ", " bad}";
  };

  # Wrap kiro-cli so it launches the way the config asks — shared by BOTH
  # backends (DRY). `--tui`/`--v3` append to the top-level `kiro-cli` launcher;
  # `--trust-tools` appends to the `kiro-cli-chat` subcommand. The new TUI is
  # rejected on the legacy engine (`--tui` alone errors; `--tui --v3` is the
  # working pair), so tui implies v3. Returns the raw package when nothing needs
  # wrapping. `environmentVariables` are baked as `--set`s only when the backend
  # has no native export path — HM passes them here (symlinkJoin is its only
  # export mechanism); devenv passes `{}` because it exports via its native `env`
  # attrset, but STILL needs the flag appends so `devenv shell` launches the v3
  # TUI exactly like HM does.
  wrapKiroPackage = {
    package,
    tui,
    v3,
    trustedMcpTools,
    environmentVariables ? {},
  }: let
    hasEnv = environmentVariables != {};
    hasTui = tui;
    hasV3 = v3 || tui;
    hasTrust = trustedMcpTools != [];
    needsWrapper = hasEnv || hasTui || hasTrust || hasV3;
    setEnvArgs =
      lib.concatStringsSep " "
      (lib.mapAttrsToList
        (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}")
        environmentVariables);
    trustToolsCsv = lib.concatStringsSep "," trustedMcpTools;
  in
    if !needsWrapper
    then package
    else
      pkgs.symlinkJoin {
        name = "kiro-cli-wrapped";
        paths = [package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          ${lib.optionalString (hasEnv || hasTui || hasV3) ''
            wrapProgram $out/bin/kiro-cli \
              ${setEnvArgs} \
              ${lib.optionalString hasTui ''--append-flags "--tui"''} \
              ${lib.optionalString hasV3 ''--append-flags "--v3"''}
          ''}
          ${lib.optionalString (hasEnv || hasTrust) ''
            wrapProgram $out/bin/kiro-cli-chat \
              ${setEnvArgs} \
              ${lib.optionalString hasTrust ''--append-flags "--trust-tools=${trustToolsCsv}"''}
          ''}
        '';
      };

  # Translate the v2 `trustedMcpTools` list into v3 `permissions.yaml`
  # rules (ONLY when v3 is active) and merge with explicit `permissions`.
  # v2 keeps using `--trust-tools` untouched. See
  # docs/plans/kiro-v3-permissions.md.
  #   "@srv"      -> { capability = mcp; match = ["srv/*"]; }
  #   "@srv/tool" -> { capability = mcp; match = ["srv/tool"]; }  (1:1)
  #   "subagent"  -> { capability = subagent; }
  #   "use_aws" / other bare tokens -> dropped (aws_tool removed in v3)
  mkPermissionRules = cfg: let
    hasV3 = cfg.v3 || cfg.tui;
    trusted = cfg.trustedMcpTools;
    mcpMatches = map (t: let
      body = lib.removePrefix "@" t;
    in
      if lib.hasInfix "/" body
      then body
      else "${body}/*")
    (builtins.filter (lib.hasPrefix "@") trusted);
    bare = builtins.filter (t: !(lib.hasPrefix "@" t)) trusted;
    hasSubagent = builtins.elem "subagent" bare;
    dropped = builtins.filter (t: t != "subagent") bare;
    translated =
      lib.optional (mcpMatches != []) {
        capability = "mcp";
        effect = "allow";
        match = mcpMatches;
      }
      ++ lib.optional hasSubagent {
        capability = "subagent";
        effect = "allow";
      };
    # Always emit capability+effect; match/exclude only when non-empty.
    renderRule = r:
      {inherit (r) capability effect;}
      // lib.optionalAttrs ((r.match or []) != []) {inherit (r) match;}
      // lib.optionalAttrs ((r.exclude or []) != []) {inherit (r) exclude;};
    rules = map renderRule (cfg.permissions ++ lib.optionals hasV3 translated);
  in
    if hasV3 && dropped != []
    then
      lib.warn
      "ai.kiro: trustedMcpTools entries not representable as v3 permissions, dropped: ${lib.concatStringsSep ", " dropped}"
      rules
    else rules;
in
  lib.ai.app.mkAiApp {
    name = "kiro";
    transformers.markdown = lib.ai.transformers.kiro;
    defaults = {
      package = pkgs.ai.kiro-cli;
    };
    options = {
      # Config directory (HOME-relative for HM, project-relative for
      # devenv). All file writes use this as root prefix. Exposed as an
      # option so consumers can override without forking the factory.
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".kiro";
        description = "Config directory relative to HOME / devenv root.";
      };
      # Kiro-scope global context (single always-on steering file). Kiro is
      # directory-native (no single-file convention), but reads AGENTS.md
      # inside `~/.kiro/steering/` as always-included content per
      # https://kiro.dev/blog/stop-repeating-yourself/. When set, this
      # option takes precedence over the top-level `ai.context`. Written
      # without frontmatter (flat always-on).
      context = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
        default = null;
        description = ''
          Kiro-scope global context. Inline string or path to a file.
          Written to `<configDir>/steering/<contextFilename>` with no frontmatter.
          When null, falls back to top-level `ai.context`.
        '';
        example = lib.literalExpression "./kiro-context.md";
      };
      # Filename under `<configDir>/steering/` for the context file. Defaults
      # to AGENTS.md since Kiro reads it natively and it's the cross-ecosystem
      # convention (shared with Codex and Copilot). Override if you want a
      # Kiro-specific filename.
      contextFilename = lib.mkOption {
        type = lib.types.str;
        default = "AGENTS.md";
        description = "Filename for the context file inside `<configDir>/steering/`.";
      };
      # Kiro-specific freeform settings with typed subkeys for known
      # knobs. Consumed by the settings/cli.json activation merge in
      # `hm.config` (runtime-merge via `jq -s '.[0] * .[1]'` to
      # preserve user runtime settings across rebuilds) and by the
      # static write in `devenv.config`.
      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            chat = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {
                  defaultModel = lib.mkOption {
                    type =
                      lib.types.nullOr
                      (lib.types.either (lib.types.enum knownKiroModels) lib.types.str);
                    default = null;
                    description = ''
                      Default chat model. Known ids
                      (packages/kiro-cli/models.json, dot-notation) autocomplete;
                      any string is accepted (non-enforcing soft enum).
                    '';
                  };
                  enableThinking = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable thinking/reasoning mode.";
                  };
                };
              };
              default = {};
              description = "Chat-related settings.";
            };
            telemetry = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {
                  enabled = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable telemetry reporting.";
                  };
                };
              };
              default = {};
              description = "Telemetry settings.";
            };
          };
        };
        default = {};
        description = ''
          JSON settings merged into ~/.kiro/settings/cli.json on activation (HM)
          or written statically (devenv). Runtime-mutated keys are preserved in HM.
          Known keys are typed; unknown keys are accepted via freeformType.
        '';
      };
      # Typed LSP server definitions for settings/lsp.json. Freeform
      # attrs-of-anything matching the legacy `attrsOf jsonFormat.type`.
      lspServers = lib.mkOption {
        type = lib.types.attrsOf (import ../../../lib/ai/ai-common.nix {inherit lib;}).lspServerModule;
        default = {};
        description = "Typed LSP server definitions; translated via `mkLspConfig` into settings/lsp.json on emission.";
      };
      # Env vars exported when launching kiro. In HM they're baked into
      # the symlinkJoin wrapper; in devenv they populate the native
      # `env` attrset. `attrsOf str` — matching the legacy surface.
      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Environment variables exported when launching kiro (HM: via wrapper; devenv: via native env).";
      };
      # Enable TUI mode — appends `--tui` to `kiro-cli`.
      tui = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Append --tui flag to the kiro-cli launcher (both backends wrap the binary; implies --v3).";
      };
      # V3 next-gen agent — appends `--v3` to the top-level `kiro-cli`
      # launcher. The granular `--agent-engine`/`--mode` flags live ONLY
      # on the `chat` subcommand and are rejected by the launcher, so the
      # launcher's sole engine selector is the `--v3` boolean. The new TUI
      # requires v3 at the launcher (bare `--tui` is rejected on 2.8.1;
      # `--tui --v3` is the working pair), so `tui = true` implies `--v3`.
      v3 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Append `--v3` (next-generation Kiro agent) to the kiro-cli
          launcher wrapper. Implied by `tui = true` (the new TUI is
          rejected on the legacy engine). Applied by both backends.
        '';
      };
      # MCP tools to auto-approve — appends `--trust-tools=<csv>`
      # to `kiro-cli-chat`. Eliminates the need for a bespoke
      # symlinkJoin wrapper in the consumer.
      trustedMcpTools = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "List of MCP tool patterns to auto-approve via --trust-tools on kiro-cli-chat (both backends).";
        example = ["@context7-mcp" "@git-mcp/git_diff" "subagent"];
      };
      # V3 capability-based permissions -> `<configDir>/settings/permissions.yaml`.
      # Mirrors Kiro's `rules:` schema 1:1 (capability / effect / match /
      # exclude). Under v3 (tui or v3) the v2 `trustedMcpTools` list is also
      # translated and merged in (see mkPermissionRules). HM-only: Kiro reads
      # permissions only from `~/.kiro/settings/` (global) or
      # `~/.kiro/workspace-roots/<hash>/`, never project `.kiro/`.
      permissions = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            capability = lib.mkOption {
              type =
                lib.types.either
                (lib.types.enum [
                  "all"
                  "builtin"
                  "context"
                  "diagnostics"
                  "filesystem"
                  "fs_read"
                  "fs_write"
                  "mcp"
                  "shell"
                  "skill"
                  "subagent"
                  "web_fetch"
                  "web_search"
                ])
                lib.types.str;
              description = "Capability category (soft enum; any string accepted).";
            };
            effect = lib.mkOption {
              type = lib.types.enum ["allow" "ask" "deny"];
              description = "deny | ask | allow (resolved by restrictiveness: deny > ask > allow).";
            };
            match = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Glob patterns (mcp: server/tool; `*` only, no `**`/`?`).";
            };
            exclude = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Glob patterns exempting resources from this rule.";
            };
          };
        });
        default = [];
        description = ''
          V3 capability-based permission rules, rendered to
          `<configDir>/settings/permissions.yaml` as `{ rules = [...]; }`
          (mirrors Kiro's schema). When v3 is active, `trustedMcpTools` is
          translated and merged. HM only.
        '';
        example = [
          {
            capability = "mcp";
            effect = "allow";
            match = ["openmemory/*" "git-mcp/git_diff"];
          }
        ];
      };
      # -- Agents & hooks --------------------------------------------------
      # GREENFIELD (held -- see docs/plans/kiro-v3-permissions.md). These are
      # UNTYPED PASSTHROUGH today: we write whatever JSON the consumer
      # authors. There is no upstream format we wrap -- Kiro OWNS these
      # schemas -- so a future session should MODEL them typed (like
      # `permissions`), not passthrough. No v2 typed surface exists, so there
      # is nothing to translate; this is net-new modeling.
      #
      # v3 agent schema (`<configDir>/agents/<name>.{json,md}`; global
      # ~/.kiro or project .kiro): { description, model, prompt,
      # tools:[tag|"*"], mcpServers:{<name>:{command,args,env,timeout}},
      # resources:["file://..."|"skill://..."],
      # permissions:[{capability,effect,match,exclude}], welcomeMessage }.
      # Tool tags: read write shell web subagent knowledge todo_list @mcp
      # @builtin *. `.md` = YAML frontmatter + system-prompt body.
      # Default agent: `kiro-cli agent set-default <name>`.
      #
      # v3 hook schema (`<configDir>/hooks/<name>.json`): { version:"v1",
      # hooks:[{ name, description?, trigger, matcher?,
      # action:{type:"command"|"agent", command|prompt}, timeout?(60),
      # enabled?(true) }] }. Triggers (PascalCase): SessionStart Stop
      # PreToolUse PostToolUse PreTaskExec PostTaskExec UserPromptSubmit
      # PostFileCreate PostFileSave PostFileDelete Manual. v2 embedded hooks
      # still work transitionally; `kiro-cli agent migrate` converts.
      # Inline agent JSON content. Written under
      # `<configDir>/agents/<name>.json` in both backends.
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = {};
        description = "Agent JSON definitions (written to <configDir>/agents/<name>.json).";
      };
      # External agents directory. Symlinked at `<configDir>/agents`
      # when set; walked recursively in devenv because devenv's
      # `files.*.source` can't recurse.
      agentsDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "External directory of agent JSON files (symlinked into <configDir>/agents).";
      };
      # Typed v3 hook records (keyed by hook name) — the northbound surface.
      # Each lowers into a `{ version:"v1", hooks:[…] }` envelope written under
      # `<configDir>/hooks/<file>.json` in both backends — `<file>` is the
      # record's attr name by default, or its `file` key to co-locate several
      # records in one envelope.
      hooks = lib.mkOption {
        type = lib.types.attrsOf kiroHookRecord;
        default = {};
        description = ''
          Typed v3 hook records, keyed by hook name. Each lowers into a
          `{ version = "v1"; hooks = [ … ]; }` envelope written to
          `<configDir>/hooks/<file>.json` on both backends — `<file>` defaults to
          the record's attribute name (one file per record), or is set explicitly
          via the record's `file` key to CO-LOCATE several records in one envelope
          (multiple hooks per file, e.g. autoMemory's set in kiro-memory.json).
          `trigger` is a soft enum from the drift-checked sidecar. Raw pre-baked
          envelopes go in `hooksJson`. v3 schema only — v2 embedded hooks are NOT
          modeled (they live in agent config; `kiro-cli agent migrate` converts
          them to v3).
        '';
        example = lib.literalExpression ''
          {
            lint = {
              trigger = "PostToolUse";
              matcher = "fs_write";
              action.command = "just lint";
              timeout = 30;
            };
          }
        '';
      };
      # Raw hook envelope JSON (escape hatch) — written verbatim to
      # `<configDir>/hooks/<name>.json`. Prefer the typed `hooks`; this exists for
      # pre-baked envelopes (autoMemory ships one here).
      hooksJson = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = {};
        description = "Raw hook envelope JSON written verbatim to <configDir>/hooks/<name>.json (escape hatch; prefer typed `hooks`).";
      };
      # External hooks directory. Symlinked at `<configDir>/hooks`
      # when set; walked recursively in devenv.
      hooksDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "External directory of hook JSON files (symlinked into <configDir>/hooks).";
      };
    };
    hm = {
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedRules,
        mergedLspServers,
        mergedEnvironmentVariables,
        topContext,
        ...
      }: let
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

        # Resolve effective context: per-CLI wins when set, else top-level.
        effectiveContext =
          if cfg.context != null
          then cfg.context
          else topContext;
        hasContext = effectiveContext != null && effectiveContext != "";

        # Resolve rule body: path → readFile; string → passthrough.
        resolveRuleText = rule:
          if builtins.isPath rule.text
          then builtins.readFile rule.text
          else rule.text;

        filteredSettings = aiCommon.filterNulls cfg.settings;
        # Kiro cli.json uses flat dot-notation keys ("chat.enableTangentMode")
        # not nested JSON. Flatten so consumers can write clean Nix:
        #   settings.chat.enableTangentMode = true;
        flatSettings = aiCommon.flattenDotKeys filteredSettings;

        # HM's only export mechanism is the symlinkJoin wrapper, so env vars
        # ride along with the --tui/--v3/--trust-tools flag appends. Shared
        # wrapper helper (also used by the devenv backend).
        kiroPackage = wrapKiroPackage {
          inherit (cfg) package tui v3 trustedMcpTools;
          environmentVariables = mergedEnvironmentVariables;
        };

        # JSON entry generation for agents and hooks (legacy mkJsonEntries).
        mkJsonEntries = subdir: attrs:
          lib.mapAttrs' (name: content:
            lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.json"
            (helpers.mkSourceEntry content))
          attrs;
      in
        lib.mkMerge [
          # Package installation — wrapped with symlinkJoin when env
          # vars are configured. Matches the legacy wrapper shape.
          {home.packages = [kiroPackage];}
          # Assertions: mutually exclusive inline/dir pairs for agents,
          # hooks, skills (steering handled by the factory's baseline
          # render + per-instruction file writes below).
          {
            assertions = [
              {
                assertion = !(cfg.agents != {} && cfg.agentsDir != null);
                message = "ai.kiro: cannot set both `agents` and `agentsDir` — choose one.";
              }
              {
                assertion = !((cfg.hooks != {} || cfg.hooksJson != {}) && cfg.hooksDir != null);
                message = "ai.kiro: cannot set both inline hooks (`hooks`/`hooksJson`) and `hooksDir` — choose one.";
              }
              (hookNameAssertion cfg)
            ];
          }
          # settings/permissions.yaml — V3 capability rules (explicit
          # `permissions` ++ translated `trustedMcpTools` under v3). Static
          # declarative write; Kiro's "Always allow" is session-scoped and
          # never mutates this file.
          (let
            permissionRules = mkPermissionRules cfg;
          in
            lib.mkIf (permissionRules != []) {
              home.file."${cfg.configDir}/settings/permissions.yaml".source = (pkgs.formats.yaml {}).generate "kiro-permissions.yaml" {
                rules = permissionRules;
              };
            })
          # settings/lsp.json — typed LSP server definitions.
          (lib.mkIf (mergedLspServers != {}) {
            home.file."${cfg.configDir}/settings/lsp.json".text =
              builtins.toJSON (lib.mapAttrs aiCommon.mkLspConfig mergedLspServers);
          })
          # settings/mcp.json — merged MCP server pool. Kiro reads this
          # natively from its config dir. Render typed entries into the
          # freeform shape Kiro expects in mcp.json.
          (lib.mkIf (mergedServers != {}) {
            home.file."${cfg.configDir}/settings/mcp.json".text = builtins.toJSON {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          })
          # Inline agent JSON files.
          (lib.mkIf (cfg.agents != {}) {
            home.file = mkJsonEntries "agents" cfg.agents;
          })
          # External agents directory — symlinked wholesale via
          # `recursive = true` (Layout B).
          (lib.mkIf (cfg.agentsDir != null) {
            home.file."${cfg.configDir}/agents" = {
              source = cfg.agentsDir;
              recursive = true;
            };
          })
          # Inline hook files — REAL files via home.activation, NOT home.file
          # (which symlinks into /nix/store). Kiro v3 scans the hooks dir but does
          # NOT follow store symlinks (verified live on 2.13.0: global scan fires
          # real files, skips symlinks), so a symlinked hook never loads. Mirrors
          # the devenv enterShell real-file install below.
          (lib.mkIf (cfg.hooks != {} || cfg.hooksJson != {}) {
            home.activation.kiroHooks = lib.hm.dag.entryAfter ["writeBoundary"] (
              helpers.mkHooksActivationScript {
                hooks = mkAllHookFiles cfg;
                hooksDir = "${cfg.configDir}/hooks";
                inherit (pkgs) coreutils;
              }
            );
          })
          # External hooks directory — REAL files via home.activation (same reason
          # as inline hooks: kiro v3 skips symlinked hook files). Mirrors the
          # devenv cp -rL.
          (lib.mkIf (cfg.hooksDir != null) {
            home.activation.kiroHooksDir = lib.hm.dag.entryAfter ["writeBoundary"] ''
              set -euETo pipefail
              shopt -s inherit_errexit 2>/dev/null || :
              HOOKS_DIR="$HOME/${cfg.configDir}/hooks"
              ${pkgs.coreutils}/bin/mkdir -p "$HOOKS_DIR"
              # Nix-owned dir: prune stale *.json first so a hook removed or
              # renamed in the source dir stops firing (Kiro loads every *.json).
              for f in "$HOOKS_DIR"/*.json; do
                if [ -e "$f" ]; then ${pkgs.coreutils}/bin/rm -f "$f"; fi
              done
              ${pkgs.coreutils}/bin/cp -rL --no-preserve=mode -- ${lib.escapeShellArg "${toString cfg.hooksDir}/."} "$HOOKS_DIR/"
              ${pkgs.coreutils}/bin/chmod -R u+w "$HOOKS_DIR"
            '';
          })
          # Per-instruction steering files — write
          # `.kiro/steering/<name>.md` for each instruction entry that
          # carries a `name` field. The kiro transformer emits
          # `inclusion:` / `fileMatchPattern:` YAML frontmatter. CRITICAL:
          # fileMatchPattern MUST be emitted as a YAML array for
          # multi-element paths — a comma-joined string silently matches
          # nothing. The kiro transformer handles this correctly.
          # Nameless entries → a dedicated `<configDir>/steering/instructions.md`
          # steering file (below); Kiro is directory-native, so context stays
          # standalone in AGENTS.md.
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
            named = builtins.filter (i: i ? name) mergedInstructions;
          in {
            home.file = lib.listToAttrs (map (instr: {
                name = "${cfg.configDir}/steering/${instr.name}.md";
                value.text = fragmentsLib.mkRenderer kiroTransformer {inherit (instr) name;} instr;
              })
              named);
          })
          # Unnamed always-on instructions → a dedicated
          # `<configDir>/steering/instructions.md` steering file. Kiro is
          # directory-native, so (unlike Claude/Copilot) context is NOT composed
          # with instructions — context stays standalone in AGENTS.md and the
          # nameless remainder that previously fed the retired generic aggregate
          # lands here. Rendered via the kiro transformer (paths-less →
          # `inclusion: always`).
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
            unnamed = builtins.filter (i: !(i ? name)) mergedInstructions;
          in
            lib.mkIf (unnamed != []) {
              home.file."${cfg.configDir}/steering/instructions.md".text =
                lib.concatMapStringsSep "\n\n" (fragmentsLib.mkRenderer kiroTransformer {}) unnamed;
            })
          # Attrs-shape ai.rules / ai.kiro.rules → <configDir>/steering/<name>.md.
          # Each entry becomes one steering file, translated through
          # kiroTransformer (inclusion: + fileMatchPattern: frontmatter).
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
          in {
            home.file = lib.mapAttrs' (name: rule:
              lib.nameValuePair "${cfg.configDir}/steering/${name}.md" {
                text = fragmentsLib.mkRenderer kiroTransformer {inherit name;} (rule
                  // {
                    text = resolveRuleText rule;
                  });
              })
            mergedRules;
          })
          # Global context → `<configDir>/steering/<contextFilename>`. Kiro
          # reads AGENTS.md (default) natively as always-included content.
          # Written without frontmatter; precedence is per-CLI > top-level.
          (lib.mkIf hasContext {
            home.file."${cfg.configDir}/steering/${cfg.contextFilename}" =
              if builtins.isPath effectiveContext
              then {source = effectiveContext;}
              else {text = effectiveContext;};
          })
          # Skills fanout via mkSkillEntries, which uses
          # `recursive = true` to produce Layout B (a real directory with
          # per-file symlinks) and is path-type-agnostic.
          {
            home.file = helpers.mkSkillEntries cfg.configDir mergedSkills;
          }
          # settings/cli.json activation merge. Preserves user-added
          # runtime keys (e.g. model selection, toggles) by merging
          # Nix-declared values on top of the existing file via
          # `jq -s '.[0] * .[1]'`. On first activation (no existing
          # file) the Nix-rendered JSON is written as-is. Ported from
          # legacy modules/kiro-cli/default.nix.
          #
          # HM-only: gated on non-empty settings so consumers who enable
          # ai.kiro just for MCP fanout don't clobber an externally-
          # managed cli.json. Matches upstream Claude HM behavior
          # (settings.json only written when cfg.settings != {}).
          # Devenv-side is unconditional (project-local, harmless).
          (lib.mkIf (filteredSettings != {}) {
            home.activation.kiroSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/settings/cli.json";
              settingsJson = builtins.toJSON flatSettings;
              jq = "${pkgs.jq}/bin/jq";
              inherit (pkgs) coreutils;
            });
          })
        ];
    };
    devenv = {
      options = {};
      config = {
        cfg,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedRules,
        mergedLspServers,
        mergedEnvironmentVariables,
        topContext,
        ...
      }: let
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
        aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

        effectiveContext =
          if cfg.context != null
          then cfg.context
          else topContext;
        hasContext = effectiveContext != null && effectiveContext != "";

        resolveRuleText = rule:
          if builtins.isPath rule.text
          then builtins.readFile rule.text
          else rule.text;

        filteredSettings = aiCommon.filterNulls cfg.settings;
        flatSettings = aiCommon.flattenDotKeys filteredSettings;
      in
        lib.mkMerge [
          # Package installation — devenv projects are shell-scoped, so
          # env exports go in the devenv `env` attrset directly (below), not
          # through the wrapper. But `--tui`/`--v3`/`--trust-tools` still need
          # appending so `devenv shell` launches the v3 TUI like HM does, so we
          # reuse the shared wrapper with an empty env set.
          {
            packages = [
              (wrapKiroPackage {
                inherit (cfg) package tui v3 trustedMcpTools;
                environmentVariables = {};
              })
            ];
          }
          # Assertions: mutually exclusive inline/dir pairs.
          {
            assertions = [
              {
                assertion = !(cfg.agents != {} && cfg.agentsDir != null);
                message = "ai.kiro: cannot set both `agents` and `agentsDir` — choose one.";
              }
              {
                assertion = !((cfg.hooks != {} || cfg.hooksJson != {}) && cfg.hooksDir != null);
                message = "ai.kiro: cannot set both inline hooks (`hooks`/`hooksJson`) and `hooksDir` — choose one.";
              }
              (hookNameAssertion cfg)
            ];
          }
          # Environment variables — devenv has a native `env` attrset
          # so no wrapper is required.
          (lib.mkIf (mergedEnvironmentVariables != {}) {
            env = lib.mapAttrs (_: lib.mkDefault) mergedEnvironmentVariables;
          })
          # settings/lsp.json — typed LSP server definitions.
          (lib.mkIf (mergedLspServers != {}) {
            files."${cfg.configDir}/settings/lsp.json".text =
              builtins.toJSON (lib.mapAttrs aiCommon.mkLspConfig mergedLspServers);
          })
          # settings/mcp.json — merged MCP server pool. Render typed
          # entries into the freeform shape Kiro expects.
          (lib.mkIf (mergedServers != {}) {
            files."${cfg.configDir}/settings/mcp.json".text = builtins.toJSON {
              mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
            };
          })
          # Inline agent JSON files.
          (lib.mkIf (cfg.agents != {}) {
            files =
              lib.concatMapAttrs (name: content: {
                "${cfg.configDir}/agents/${name}.json".text = content;
              })
              cfg.agents;
          })
          # External agents directory — devenv's `files.*.source`
          # can't recurse, so we walk the directory at eval time.
          (lib.mkIf (cfg.agentsDir != null) (let
            walkDir = prefix: dir:
              lib.concatMapAttrs (
                name: kind:
                  if kind == "directory"
                  then walkDir "${prefix}/${name}" (dir + "/${name}")
                  else if kind == "regular" || kind == "symlink"
                  then {"${prefix}/${name}".source = dir + "/${name}";}
                  else {}
              )
              (builtins.readDir dir);
          in {
            files = walkDir "${cfg.configDir}/agents" cfg.agentsDir;
          }))
          # Inline hook JSON files — written as REAL files via enterShell, NOT
          # devenv `files.*` (which symlinks into /nix/store). Kiro v3 discovers
          # workspace hooks by scanning `${cfg.configDir}/hooks/` with read_dir
          # and does NOT follow a store symlink (the scan skips it), so a
          # symlinked hook never loads and `/hooks` shows nothing. See the
          # kiro-v3-hooks-workspace-local finding + docs/plans/kiro-cli-auto-memory.md.
          #
          # NOTE: this comment previously claimed "steering and agents load
          # fine as symlinks". That is almost certainly WRONG, and the
          # mechanism described just above is why: steering is discovered by
          # the same directory scan, so the same skip applies. Upstream
          # corroborates — kirodotdev/Kiro#2921 ("Follow symlinks for steering
          # docs", still open) and #8121 ("Only a real file copy at
          # .kiro/steering/AGENTS.md works").
          #
          # The steering/rules emitters below therefore still ship store
          # symlinks to consumers. Converting them is NOT mechanical: the
          # emission shape is asserted declaratively by
          # checks/module-eval.nix (config.files / config.home.file), and an
          # imperative copy would leave those assertions checking script text
          # instead of an attrset. Tracked as follow-up, deliberately not
          # bundled with the repo-local materializer change.
          (lib.mkIf (cfg.hooks != {} || cfg.hooksJson != {}) {
            enterShell = ''
              ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${cfg.configDir}/hooks"}
              # devenv-owned dir: prune stale *.json so a hook removed or renamed
              # in config stops firing (Kiro loads every *.json in the dir).
              for f in ${lib.escapeShellArg "${cfg.configDir}/hooks"}/*.json; do
                if [ -e "$f" ]; then ${pkgs.coreutils}/bin/rm -f "$f"; fi
              done
              ${lib.concatStrings (lib.mapAttrsToList (name: content: ''
                  ${pkgs.coreutils}/bin/install -m 0644 ${pkgs.writeText "kiro-hook-${name}.json" content} ${lib.escapeShellArg "${cfg.configDir}/hooks/${name}.json"}
                '')
                (mkAllHookFiles cfg))}
            '';
          })
          # External hooks directory — copied as REAL files (same reason as the
          # inline hooks above: kiro v3 skips symlinked hook files).
          (lib.mkIf (cfg.hooksDir != null) {
            enterShell = ''
              ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${cfg.configDir}/hooks"}
              # devenv-owned dir: prune stale *.json so a hook removed or renamed
              # in the source dir stops firing (Kiro loads every *.json in the dir).
              for f in ${lib.escapeShellArg "${cfg.configDir}/hooks"}/*.json; do
                if [ -e "$f" ]; then ${pkgs.coreutils}/bin/rm -f "$f"; fi
              done
              ${pkgs.coreutils}/bin/cp -rL --no-preserve=mode -- ${lib.escapeShellArg "${toString cfg.hooksDir}/."} ${lib.escapeShellArg "${cfg.configDir}/hooks/"}
              ${pkgs.coreutils}/bin/chmod -R u+w ${lib.escapeShellArg "${cfg.configDir}/hooks"}
            '';
          })
          # Per-instruction steering files under `.kiro/steering/`.
          # Same transformer as HM, same filter-by-name pattern.
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
            named = builtins.filter (i: i ? name) mergedInstructions;
          in {
            files = lib.listToAttrs (map (instr: {
                name = "${cfg.configDir}/steering/${instr.name}.md";
                value.text = fragmentsLib.mkRenderer kiroTransformer {inherit (instr) name;} instr;
              })
              named);
          })
          # Unnamed always-on instructions → a dedicated
          # `<configDir>/steering/instructions.md` steering file (parity with
          # HM). Context stays standalone in AGENTS.md; this catches the
          # nameless remainder that previously fed the retired generic aggregate.
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
            unnamed = builtins.filter (i: !(i ? name)) mergedInstructions;
          in
            lib.mkIf (unnamed != []) {
              files."${cfg.configDir}/steering/instructions.md".text =
                lib.concatMapStringsSep "\n\n" (fragmentsLib.mkRenderer kiroTransformer {}) unnamed;
            })
          # Attrs-shape ai.rules / ai.kiro.rules → steering files (parity with HM).
          (let
            fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
            inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
          in {
            files = lib.mapAttrs' (name: rule:
              lib.nameValuePair "${cfg.configDir}/steering/${name}.md" {
                text = fragmentsLib.mkRenderer kiroTransformer {inherit name;} (rule
                  // {
                    text = resolveRuleText rule;
                  });
              })
            mergedRules;
          })
          # Global context → `<configDir>/steering/<contextFilename>`.
          # Mirrors HM side; no frontmatter, per-CLI wins over top-level.
          (lib.mkIf hasContext {
            files."${cfg.configDir}/steering/${cfg.contextFilename}" =
              if builtins.isPath effectiveContext
              then {source = effectiveContext;}
              else {text = effectiveContext;};
          })
          # Skills via the user-space walker. devenv's `files.*.source`
          # cannot walk a directory recursively, so we enumerate leaves
          # at eval time via `mkDevenvSkillEntries`.
          {
            files = helpers.mkDevenvSkillEntries cfg.configDir mergedSkills;
          }
          # settings/cli.json — devenv does NOT support HM-style
          # activation scripts. Devenv projects are project-local, so
          # there's no runtime-mutation preservation concern. Static
          # JSON write is sufficient.
          (lib.mkIf (filteredSettings != {}) {
            files."${cfg.configDir}/settings/cli.json".text =
              builtins.toJSON flatSettings;
          })
        ];
    };
  }

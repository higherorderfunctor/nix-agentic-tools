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
  # Launcher/chat wrapper: idempotent flag injection plus the HM env bake.
  # Lifted out of this file so it has a seam a check can drive directly.
  # See packages/kiro-cli/lib/wrapPackage.nix.
  wrapKiroPackage = import ./wrapPackage.nix {inherit lib pkgs;};

  # Engine-bundle rewrites. Both reach INTO the KAS bundle, which is unpacked
  # from the binary at runtime and never lands in the nix store, so both are
  # runtime helpers rather than derivations. Each file's header records why
  # build-time extraction is not available.
  mkIdentityMaterializer = import ./identityBundle.nix {inherit lib pkgs;};
  workflowReminder = import ./workflowReminder.nix {inherit lib pkgs;};

  # Shared AI helpers (filterNulls, mkLspConfig, flattenDotKeys, …). Hoisted to
  # the top-level `let` so option TYPES and renderers can reach it too — both
  # backend blocks previously imported it separately.
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};

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

  # Kiro's runtime capability set (`VALID_CAPABILITIES`). Kept a SOFT enum —
  # `either (enum …) str` — because Kiro validates capabilities against a
  # runtime table and SKIPS an unknown one with a warning rather than
  # rejecting the file, so a closed Nix enum would be stricter than the
  # binary. `power` and `sandbox_network` were absent from the hand-written
  # list this replaced. Note `all` expands to the ten builtins plus `mcp` and
  # does NOT cover `sandbox_network`.
  kiroCapabilities = [
    "all"
    "builtin"
    "context"
    "diagnostics"
    "filesystem"
    "fs_read"
    "fs_write"
    "mcp"
    "power"
    "sandbox_network"
    "shell"
    "skill"
    "subagent"
    "web_fetch"
    "web_search"
  ];

  # One capability rule. Shared by `ai.kiro.permissions` (which renders
  # `settings/permissions.yaml`) and by a typed agent's own `permissions.rules`
  # — same wire shape in both places, so it is defined once.
  kiroPermissionRule = lib.types.submodule {
    options = {
      capability = lib.mkOption {
        type = lib.types.either (lib.types.enum kiroCapabilities) lib.types.str;
        description = "Capability category (soft enum; any string accepted — Kiro skips unknown ones with a warning).";
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
  };

  # A knowledge-base resource entry. `resources` elements are either a bare
  # URI string (`file://…` / `skill://…`) or one of these.
  kiroKnowledgeBaseResource = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["knowledgeBase"];
        default = "knowledgeBase";
        description = "Discriminator; the only accepted value.";
      };
      source = lib.mkOption {
        type = lib.types.str;
        description = "Must be a `file://` URI with a non-empty path.";
      };
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Display name.";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Human-readable description.";
      };
      indexType = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["best" "fast"]);
        default = null;
        description = "Index strategy (a real closed enum in Kiro's schema).";
      };
      include = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Glob patterns to include.";
      };
      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Glob patterns to exclude.";
      };
      autoUpdate = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "true → re-index on agent load; false/null → never.";
      };
    };
  };

  # Agent-scoped permission block (`permissions` in an agent file).
  kiroAgentPermissions = lib.types.submodule {
    options = {
      rules = lib.mkOption {
        type = lib.types.listOf kiroPermissionRule;
        default = [];
        description = "Capability rules scoping down what this agent may do.";
      };
      policies = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Named preset policy ids expanded inline into scoped rules. Kiro ships
          `allow-all`, `dev-shell`, `edit-workspace`, `read-all`,
          `read-only-shell`, `read-workspace`; an unknown id is skipped with a
          warning, so this stays a plain string list rather than a closed enum.
        '';
      };
    };
  };

  # A typed v3 agent record. Field set mirrors `JsonAgentFileSchema` as read
  # out of the ACP bundle (`acp-server.js`, 2.16.0). Un-modeled fields —
  # notably `mcpServers` and inline `hooks` — round-trip through the freeform
  # JSON tail; they are deliberately NOT modeled here because both already
  # have their own typed pools in this module whose composition with an
  # agent-scoped copy is a design question, not a mechanical mapping.
  #
  # Only `dispatchKind` and the nested `effect`/`indexType` are real closed
  # enums in Kiro's schema, so only those are `types.enum` here. Kiro's other
  # enum-looking fields are runtime tables that skip-with-warning, and the
  # schema itself lives in a bundle downloaded at runtime under
  # ~/.local/share/kiro-cli/kas/ — NOT in the Nix store — so it cannot feed
  # the drift-checked extraction sidecar the way `hookTriggers` does. Closed
  # enums copied from it by hand would rot unguarded; they stay `str`.
  kiroAgentRecord = lib.types.submodule {
    freeformType = (pkgs.formats.json {}).type;
    options = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Agent id. Defaults to the attribute key, which is also the filename
          stem. Kiro's Rust CLI REQUIRES this field and rejects an agent file
          without it, while the ACP path treats it as optional and falls back
          to the filename — so it is always emitted.
        '';
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Human-facing guidance shown in `kiro-cli agent list`.";
      };
      prompt = lib.mkOption {
        type = lib.types.nullOr (lib.types.coercedTo lib.types.path builtins.readFile lib.types.str);
        default = null;
        description = "System prompt. A Nix path is read at eval time into inline content.";
      };
      tools = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.listOf lib.types.str));
        default = null;
        description = ''Tool ids, or the literal `"*"` for all tools.'';
      };
      excludedTools = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Tools to exclude, applied after `tools` matching.";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Model override for this agent.";
      };
      effortLevel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Reasoning effort for reasoning-capable models.";
      };
      includeMcpJson = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Include all MCP tools (Kiro default false: MCP tools only via explicit `tools` patterns).";
      };
      includePowers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Include the kiroPowers tool (Kiro default false).";
      };
      welcomeMessage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Message shown when switching to this agent.";
      };
      dispatchKind = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["custom-agent" "spec" "sub-agent"]);
        default = null;
        description = ''
          Which dispatch adapter runs this agent. A real closed enum in Kiro's
          schema. Note agents carrying sub-agent-shaped fields are filtered out
          of `kiro-cli agent list` while still loading and running normally.
        '';
      };
      resources = lib.mkOption {
        type = lib.types.listOf (lib.types.either lib.types.str kiroKnowledgeBaseResource);
        default = [];
        description = ''
          Context resources: `file://` / `skill://` URI strings, or knowledge-base
          records. Kiro drops an unrecognized entry with a warning.
        '';
      };
      permissions = lib.mkOption {
        type = lib.types.nullOr kiroAgentPermissions;
        default = null;
        description = "Capability policy scoping down this agent.";
      };
    };
  };

  # Drop nulls AND empty collections, recursively, so an agent file carries
  # only what was actually declared. `aiCommon.filterNulls` is not enough on
  # its own: it drops `null` and `{}` but KEEPS `[]`, so a list-valued option
  # whose default is `[]` (`resources`, and `match`/`exclude` inside a
  # permission rule) would leak `"resources": []` into every emitted agent.
  # Kept local rather than widening `filterNulls`, whose empty-list behavior
  # other emitters in this repo already depend on.
  # Recurses through LISTS as well as attrsets: `permissions.rules` and
  # `resources` are lists of submodules, and their elements carry their own
  # `[]` defaults (`match`/`exclude`, `include`/`exclude`). Walking attrsets
  # alone returns the list untouched and leaks `"match": []` into every rule.
  # List elements are pruned in place, never dropped — removing one would
  # change which rules apply, not just how the file reads.
  pruneEmptyAgentFields = value:
    if lib.isList value
    then map pruneEmptyAgentFields value
    else if lib.isAttrs value && !(lib.isDerivation value)
    then
      lib.filterAttrs (_: v: v != null && v != {} && v != [])
      (lib.mapAttrs (_: pruneEmptyAgentFields) value)
    else value;

  # Render one typed agent record → its JSON text. `attrName` supplies `name`
  # unless the record overrides it — Kiro keys the agent on `name`, so the two
  # must agree or the agent lists under an id that does not match its file.
  # Null optionals and empty collections are dropped so the emitted file stays
  # the minimal shape both parsers accept.
  renderAgent = attrName: record: let
    named = record // {name = record.name or null;};
    withName =
      named
      // {
        name =
          if named.name == null
          then attrName
          else named.name;
      };
  in
    builtins.toJSON (pruneEmptyAgentFields withName);

  # A typed record is a plain attrset; raw entries are strings or paths (a
  # derivation is stringLike and must stay on the raw path).
  isTypedAgent = value: builtins.isAttrs value && !(lib.isDerivation value);

  # One `agents` entry → the `{source|text}` attrs BOTH backends write, so the
  # two cannot drift. Previously HM routed a path to `source` while devenv
  # assigned it to `.text`, which wrote the store path STRING as the file body
  # instead of its contents; going through one helper fixes that asymmetry.
  mkAgentEntry = attrName: value:
    if isTypedAgent value
    then {text = renderAgent attrName value;}
    else if lib.isPath value
    then {source = value;}
    else {text = value;};

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

  # Shared strategy-driven materializer (lib/ai/materialize.nix) — the
  # steering AND hook writers for both backends, plus the single source of
  # the name-safety regex shared by both surfaces' copy-mode names.
  materializeLib = import ../../../lib/ai/materialize.nix {inherit lib;};

  # Hook names are attrset keys interpolated straight into the generated
  # writer's shell words, target paths, grep patterns and temp-sweep glob, so
  # a `/`, `..`, whitespace, or quote would write outside the hooks dir or
  # break the emitted script. Require a leading alphanumeric then
  # `[A-Za-z0-9._-]` (covers kiro-memory, pre-commit, lint) — the same
  # charset gating copy-mode steering names (materializeLib.nameSafe).
  # Shared assertion for both backends.
  hookNameSafe = materializeLib.nameSafe;

  # Where Kiro reads hooks from. BOTH hook surfaces land here.
  hookTargetDir = cfg: "${cfg.configDir}/hooks";

  # `steeringFiles` gets `text`/`source` defaulted by its option submodule;
  # hook entries are plain factory-internal values, so they must carry BOTH
  # fields explicitly — the materializer reads whichever is null to decide
  # shape, and a missing attribute is an eval error rather than a default.
  mkHookEntry = attrs:
    {
      text = null;
      source = null;
      strategy = "copy";
    }
    // attrs;

  # `hooksDir` contributes the source directory's TOP-LEVEL `*.json` files,
  # enumerated at eval (same idiom as the devenv `agentsDir` walker below;
  # a `hooksDir` pointing at a derivation OUTPUT is therefore IFD, which the
  # activation-time `cp -rL` this replaced was not).
  #
  # Three things are deliberately dropped vs. that `cp -rL`, each of them
  # something Kiro never loaded AND the old whole-dir prune never removed: nested
  # subdirectories are not recursed, non-`.json` entries (a README, a
  # `.gitkeep`) are not copied, and the installed mode is the
  # materializer's read-only 0444 rather than 0644. The `.json` filter is
  # also what keeps a `.gitkeep` from tripping the copy-mode name regex,
  # which bars leading dots.
  hooksDirEntries = dir:
    lib.concatMapAttrs (
      name: kind:
        if (kind == "regular" || kind == "symlink") && lib.hasSuffix ".json" name
        then {${name} = mkHookEntry {source = dir + "/${name}";};}
        else {}
    )
    (builtins.readDir dir);

  # Lower whichever hook surface is set — inline (`hooks`/`hooksJson`) or the
  # external `hooksDir` — into ONE materializer entry set, so the two share a
  # manifest and a consumer flipping between them prunes the previous
  # surface's files instead of orphaning them. The two are mutually exclusive
  # (see `mkAssertions`), so the branch never has to merge them.
  #
  # `strategy` is always "copy" and there is deliberately NO symlink escape
  # hatch here (unlike `steeringStrategy`): the v3 engine's hook scan keeps
  # only `entry.isFile()` entries, so a symlinked hook silently never loads
  # (kirodotdev/Kiro#9787). A strategy option would only offer a way to break
  # hooks.
  mkHookEntries = cfg:
    if cfg.hooksDir != null
    then hooksDirEntries cfg.hooksDir
    else
      lib.mapAttrs' (name: content:
        lib.nameValuePair "${name}.json" (mkHookEntry {text = content;}))
      (mkAllHookFiles cfg);

  hookNameAssertion = cfg: let
    bad =
      builtins.filter (n: !hookNameSafe n)
      (builtins.attrNames cfg.hooks ++ builtins.attrNames cfg.hooksJson);
  in {
    assertion = bad == [];
    message = "ai.kiro: hook names must match ${materializeLib.nameRegex} (no path separators, whitespace, or quotes); offending: ${lib.concatStringsSep ", " bad}";
  };

  # Shared assertion set for both backends: mutually exclusive
  # inline/dir pairs, hook-name charset, and the steering-entry
  # shape/name guards (exactly-one-of text/source; copy-mode names).
  mkAssertions = cfg:
    [
      {
        assertion = !(cfg.agents != {} && cfg.agentsDir != null);
        message = "ai.kiro: cannot set both `agents` and `agentsDir` — choose one.";
      }
      {
        assertion = !((cfg.hooks != {} || cfg.hooksJson != {}) && cfg.hooksDir != null);
        message = "ai.kiro: cannot set both inline hooks (`hooks`/`hooksJson`) and `hooksDir` — choose one.";
      }
      (hookNameAssertion cfg)
      {
        # The splice reassembles the literal as `replacement + " " + tail`. If
        # the replacement does not close its own final sentence it MERGES into
        # the vendor tail ("You are GLaDOS You operate in a terminal
        # environment: …"), and the option stops meaning "replace the first
        # sentence" at all.
        #
        # Asserted at EVAL, not left to the splicer's own guard (which stays as
        # a backstop). The splicer runs on the LAUNCH path, and that path FAILS
        # OPEN by design — so a value rejected there presents as "the identity
        # silently did nothing", which is precisely the failure shape that let
        # a multi-sentence identity ship broken. A config error belongs where
        # the config is written.
        assertion =
          cfg.identity
          == null
          || builtins.match ".*[.!?][[:space:]]*" cfg.identity != null;
        message = ''
          ai.kiro: `identity` must end with sentence punctuation (`.`, `!` or
          `?`). It replaces the FIRST SENTENCE of the vendor identity and the
          preserved remainder is re-joined directly after it, so a value that
          does not close its own sentence runs INTO that remainder instead of
          replacing a sentence.
        '';
      }
      {
        # An overridden `package` need not carry the overlay's passthru, and
        # without this the failure is a bare "attribute 'withRolloutFeatures'
        # missing" pointing at factory internals rather than at the two
        # options the consumer actually set.
        assertion =
          cfg.unlockedRolloutFeatures == [] || cfg.package ? withRolloutFeatures;
        message = ''
          ai.kiro: `unlockedRolloutFeatures` needs a `package` exposing
          `passthru.withRolloutFeatures`, which `pkgs.ai.kiro-cli` from this
          flake's overlay provides. The configured `package` does not, so it
          cannot be patched. Either drop `unlockedRolloutFeatures` or set
          `package` back to an overlay-provided kiro-cli.
        '';
      }
      {
        # Without this the misconfiguration is SILENT and costs a debugging
        # session: the package really is patched, the option really is set, and
        # the feature is simply never visible. Measured on a consumer repo that
        # set `enable` + `unlockedRolloutFeatures` and nothing else.
        #
        # Two independent reasons it does nothing, neither of which errors:
        #   1. `needsWrapper` keys off v3 / trustedMcpTools /
        #      environmentVariables — NOT this option — so the package ships
        #      unwrapped and nothing injects `--v3`.
        #   2. Workflow slash-commands are populated only when the resolved
        #      engine is `kas`; on the legacy engine they are filtered out.
        assertion = cfg.unlockedRolloutFeatures == [] || cfg.v3;
        message = ''
          ai.kiro: `unlockedRolloutFeatures` requires `v3 = true`.

          The features are surfaced only by the v3 (`kas`) engine, and nothing
          else in this module injects `--v3`, so as configured the binary would
          be patched and the features would stay invisible with no error.

          Set `ai.kiro.v3 = true`, or drop `unlockedRolloutFeatures`.
        '';
      }
    ]
    ++ materializeLib.mkEntryAssertions {
      app = "kiro";
      surface = "steering";
      files = cfg.steeringFiles;
    }
    # Hook entries ride the same writers, so they need the same guards.
    # `hookNameAssertion` above covers only the INLINE surfaces' attr keys;
    # this is what catches a `hooksDir` whose filenames are unsafe to
    # interpolate into the generated shell.
    ++ materializeLib.mkEntryAssertions {
      app = "kiro";
      surface = "hook";
      files = mkHookEntries cfg;
    };

  # The four steering emitters (named-instr / unnamed-instr / rules /
  # context) are backend-agnostic: they populate `ai.kiro.steeringFiles`
  # instead of writing home.file/files.* directly; the per-backend
  # strategy-driven writer element does the delivery. Every emitter
  # stamps `strategy = cfg.steeringStrategy` explicitly — the shared
  # options block is inert data with no `config` access, so the
  # submodule cannot default it. The four elements keep their mkMerge
  # boundaries + mkIf gates; `steeringFiles.<n>.text` is `nullOr str`,
  # so two emitters producing the same key with DIFFERENT content is a
  # hard eval error and equal content dedupes.
  mkSteeringEmitters = {
    cfg,
    mergedInstructions,
    mergedRules,
    topContext,
  }: let
    fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
    inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
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
    mkEntry = text: {
      inherit text;
      strategy = cfg.steeringStrategy;
    };
    named = builtins.filter (i: i ? name) mergedInstructions;
    unnamed = builtins.filter (i: !(i ? name)) mergedInstructions;
  in [
    # Per-instruction steering entries — `<name>.md` for each
    # instruction carrying a `name`. The kiro transformer emits
    # `inclusion:` / `fileMatchPattern:` YAML frontmatter. CRITICAL:
    # fileMatchPattern MUST be emitted as a YAML array for
    # multi-element paths — a comma-joined string silently matches
    # nothing. The kiro transformer handles this correctly.
    {
      ai.kiro.steeringFiles = lib.listToAttrs (map (instr: {
          name = "${instr.name}.md";
          value = mkEntry (fragmentsLib.mkRenderer kiroTransformer {inherit (instr) name;} instr);
        })
        named);
    }
    # Unnamed always-on instructions → a dedicated `instructions.md`
    # steering entry. Kiro is directory-native, so (unlike
    # Claude/Copilot) context is NOT composed with instructions —
    # context stays standalone in AGENTS.md and the nameless remainder
    # that previously fed the retired generic aggregate lands here
    # (paths-less → `inclusion: always`).
    (lib.mkIf (unnamed != []) {
      ai.kiro.steeringFiles."instructions.md" =
        mkEntry (lib.concatMapStringsSep "\n\n" (fragmentsLib.mkRenderer kiroTransformer {}) unnamed);
    })
    # Attrs-shape ai.rules / ai.kiro.rules → `<name>.md` entries,
    # translated through kiroTransformer (inclusion: +
    # fileMatchPattern: frontmatter). Rule paths resolve to text at
    # eval via resolveRuleText.
    {
      ai.kiro.steeringFiles = lib.mapAttrs' (name: rule:
        lib.nameValuePair "${name}.md" (mkEntry (fragmentsLib.mkRenderer kiroTransformer {inherit name;} (rule
          // {
            text = resolveRuleText rule;
          }))))
      mergedRules;
    }
    # Global context → `<contextFilename>` (default AGENTS.md — Kiro
    # reads it natively as always-included content). Written without
    # frontmatter; per-CLI wins over top-level. Under copy strategy a
    # path-valued context normalizes to `text` at eval via readFile
    # (the writer heredoc-embeds content); `source` is kept only for
    # symlink strategy.
    (lib.mkIf hasContext {
      ai.kiro.steeringFiles.${cfg.contextFilename} =
        if !(builtins.isPath effectiveContext)
        then mkEntry effectiveContext
        else if cfg.steeringStrategy == "copy"
        then mkEntry (builtins.readFile effectiveContext)
        else {
          source = effectiveContext;
          strategy = cfg.steeringStrategy;
        };
    })
  ];

  # Translate the v2 `trustedMcpTools` list into v3 `permissions.yaml`
  # rules (ONLY when v3 is active) and merge with explicit `permissions`.
  # v2 keeps using `--trust-tools` untouched. See
  # docs/plans/kiro-v3-permissions.md.
  #   "@srv"      -> { capability = mcp; match = ["srv/*"]; }
  #   "@srv/tool" -> { capability = mcp; match = ["srv/tool"]; }  (1:1)
  #   "subagent"  -> { capability = subagent; }
  #   "use_aws" / other bare tokens -> dropped (aws_tool removed in v3)
  mkPermissionRules = cfg: let
    hasV3 = cfg.v3;
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

  # Both backends must apply the unlock identically (config parity is a repo
  # invariant, not a nicety), so the resolution lives here rather than being
  # open-coded at each `wrapKiroPackage` call site.
  #
  # `cfg.package` is evaluated either way, which is what keeps the unfree guard
  # honest: `pkgs.ai.kiro-cli` is an `ensureUnfreeCheck` symlinkJoin, so
  # check-meta fires on it before `withRolloutFeatures` is ever reached.
  # No canonicalization here on purpose. `withRolloutFeatures` sorts and
  # de-duplicates its own argument (see `canonFeatures` in
  # overlays/kiro-cli.nix), because that is where derivation identity is
  # decided and doing it there covers direct callers too. Repeating it here
  # would be a second source of truth that can silently drift out of step.
  resolvePackage = cfg:
    if cfg.unlockedRolloutFeatures == []
    then cfg.package
    else cfg.package.withRolloutFeatures cfg.unlockedRolloutFeatures;

  # ── Engine-bundle rewrites, shared by BOTH backends (config parity) ────────
  # These three live here rather than in either backend block for the same
  # reason `resolvePackage` does: a surface configurable under home-manager
  # must be configurable under devenv, and one definition is what keeps the two
  # from drifting.

  # The materializer is version-pinned, so it must be built from the RESOLVED
  # package (a rollout-unlocked variant is a different derivation but the same
  # version) rather than from `cfg.package`.
  resolveIdentityMaterializer = cfg:
    if cfg.identity == null
    then null
    else
      mkIdentityMaterializer {
        inherit (cfg) identity;
        cliVersion = (resolvePackage cfg).version;
      };

  # `null` means auto: the reminder is meaningless without the feature, and the
  # feature under-elicits without it, so they default on together.
  workflowReminderEnabled = cfg:
    if cfg.workflowReminder.enable != null
    then cfg.workflowReminder.enable
    else builtins.elem "workflows" cfg.unlockedRolloutFeatures;

  # Contributed as an ordinary typed hook record, so it rides the existing
  # envelope writer on both backends instead of adding a second hook path.
  #
  # `type = "agent"` appends the prompt straight to model context with no
  # subprocess (and ignores `timeout`), which is why the SHORT reminder needs no
  # script at all. The vendor-steering variant has to be `type = "command"`:
  # its text lives in the runtime-unpacked engine bundle, so it cannot be a
  # string known at eval time.
  workflowReminderHooks = cfg:
    lib.optionalAttrs (workflowReminderEnabled cfg) {
      workflow-reminder =
        {
          trigger = "UserPromptSubmit";
          description = "Re-state the workflow orchestration contract each turn (position, not content — see workflowReminder.nix).";
        }
        // (
          if cfg.workflowReminder.includeVendorSteering
          then {
            action = {
              type = "command";
              command = workflowReminder.mkVendorReminder {
                cliVersion = (resolvePackage cfg).version;
              };
            };
            # The extractor reads a 20 MB file on a cold cache; every later turn
            # is a `cat`. Kiro's default is 60s, which is ample, but a hook that
            # hangs blocks the turn, so this is bounded explicitly.
            timeout = 30;
          }
          else {
            action = {
              type = "agent";
              prompt = cfg.workflowReminder.text;
            };
          }
        );
    };

  # Rendered mcp.json body (DRY: both backends AND the mkMcpJsonScript
  # template use this — was duplicated inline per backend). `kiroServers`
  # is the preprocessed pool: credential headers already `${env:VAR}`,
  # credential urls already a `${VAR}` envsubst sentinel (mcpSecrets.nix).
  mcpJsonText = kiroServers:
    builtins.toJSON {
      mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) kiroServers;
    };

  # Shell body that (re)assembles settings/mcp.json as a REAL file at
  # activation (HM) / shell entry (devenv), shared by both backends so
  # they stay at parity. `mode` = `ai.kiro.mcpWriteMode`:
  #   * "overwrite" — write the rendered template and lock it read-only;
  #     Nix is authoritative, hand edits do not survive.
  #   * "merge" — deep-merge the Nix-managed servers onto whatever is on
  #     disk (`jq '.[0] * .[1]'`, write-if-absent) and leave it writeable,
  #     preserving hand-added servers/edits.
  # A credential url is substituted in HERE: `urlSecretEnv` vars are
  # exported from their decrypted secret and `envsubst`'d into the
  # template with an EXPLICIT var list, so header `${env:...}`
  # placeholders (which Kiro expands at launch) survive untouched. Empty
  # `urlSecretEnv` → the template is used verbatim. `targetExpr` is a
  # shell expression for the destination (absolute for HM, relative to
  # $DEVENV_ROOT for devenv). Uniform real-file delivery (never a store
  # symlink) is what lets a secret url land and dodges the
  # symlink<->real-file toggle + the devenv files.* silent skip. NOTE:
  # a credential url reads its secret at ACTIVATION, so a consumer wiring
  # sops-nix/agenix must order this after the secret provider (P2). That
  # ordering is still the consumer's to get right, but getting it WRONG is no
  # longer silent: an unreadable or empty secret now fails activation loudly
  # instead of writing `"url": ""` and leaving the server to fail at runtime.
  mkMcpJsonScript = {
    mode,
    templateFile,
    urlSecretEnv,
    targetExpr,
  }: let
    hasUrlSecret = urlSecretEnv != {};
    # r-- lock for overwrite; owner-writeable for merge; owner-only when
    # a secret url is written into the file.
    fileMode =
      if mode == "overwrite"
      then
        (
          if hasUrlSecret
          then "0400"
          else "0444"
        )
      else if hasUrlSecret
      then "0600"
      else "0644";
    # A BARE assignment, then a SEPARATE `export`. `export VAR="$(cmd)"` is a
    # silent-failure trap: the exit status of that line is `export`'s — always
    # 0 — so a failed read does NOT trip errexit, not even with
    # `inherit_errexit` set. The empty value then flows into envsubst, which
    # cheerfully writes `"url": ""`, producing an MCP server that never loads
    # and reports nothing. A plain `VAR="$(cmd)"` takes the command
    # substitution's status instead, so an unreadable secret aborts activation.
    #
    # Measured 2026-08-04: a gateway url whose secret was not yet readable when
    # this block ran wrote `"url": ""` into ~/.kiro/settings/mcp.json, and the
    # only symptom was jira/confluence quietly failing to load.
    #
    # The emptiness check covers the other half of the same failure: a secret
    # file that EXISTS but is empty reads successfully and is just as broken,
    # so length is checked rather than trusting the exit status alone.
    exports = lib.concatStrings (lib.mapAttrsToList (var: cred: let
        isFile = (cred.file or null) != null;
        reader =
          if isFile
          then ''"$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg cred.file})"''
          else ''"$(${lib.escapeShellArg cred.helper})"'';
        source =
          if isFile
          then cred.file
          else cred.helper;
      in ''
        ${var}=${reader}
        if [ -z "''${${var}}" ]; then
          echo "kiro mcp: credential for ${var} (${source}) is empty — refusing to write an mcp.json with a blank url" >&2
          false
        fi
        export ${var}
      '')
      urlSecretEnv);
    envsubstVars =
      lib.concatMapStringsSep " " (v: "\${${v}}") (builtins.attrNames urlSecretEnv);
    # Produce $RENDERED from the store template (envsubst only the url
    # vars when there is a secret url; a plain copy otherwise).
    assemble =
      if hasUrlSecret
      then "${exports}${pkgs.gettext}/bin/envsubst ${lib.escapeShellArg envsubstVars} < ${templateFile} > \"$RENDERED\""
      else ''${pkgs.coreutils}/bin/cp ${templateFile} "$RENDERED"'';
    # Land $RENDERED at $TARGET per mode. `rm -f` first clears a stale
    # store symlink from a prior generation (a bare `cp` would follow it
    # into the read-only store and fail); merge only merges a REAL
    # user-owned file, treating a symlink/absent target as write-fresh.
    writeStep =
      if mode == "overwrite"
      then ''
        ${pkgs.coreutils}/bin/rm -f "$TARGET"
        ${pkgs.coreutils}/bin/cp "$RENDERED" "$TARGET"''
      else ''
        if [ -f "$TARGET" ] && [ ! -L "$TARGET" ]; then
          MERGED="$(${pkgs.coreutils}/bin/mktemp)"
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$TARGET" "$RENDERED" > "$MERGED"
          ${pkgs.coreutils}/bin/mv "$MERGED" "$TARGET"
        else
          ${pkgs.coreutils}/bin/rm -f "$TARGET"
          ${pkgs.coreutils}/bin/cp "$RENDERED" "$TARGET"
        fi'';
    # SCOPED in a subshell — required, for two independent reasons:
    #
    #   1. Home Manager concatenates every activation DAG entry into ONE script
    #      that it opens with its own `set -eu` + pipefail. A bare strict-mode
    #      header here therefore persists into every LATER entry and into home
    #      manager's own code. The repo Bash standard mandates scoping for
    #      exactly this reason; this body was the one activation writer not
    #      following it.
    #   2. `${exports}` puts a decrypted SECRET in the environment. Unscoped,
    #      that value stays exported for the remainder of activation, visible to
    #      every subsequent entry and anything they spawn. A subshell confines it
    #      to the envsubst that needs it.
    #
    # The body has no parent-shell effects to preserve (the exports are
    # deliberately transient), so scoping costs nothing. Failure still
    # propagates: the subshell exits non-zero and the caller's `set -e` sees it,
    # which is why the guards above end in `false` rather than `exit` — `exit`
    # would truncate the whole concatenated activation script.
    #
    # devenv already wraps this body via `anchorToDevenvRoot`; the extra nesting
    # there is harmless and keeps the invariant one property of THIS function
    # rather than of each call site.
  in ''
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      TARGET="${targetExpr}"
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$TARGET")"
      RENDERED="$(${pkgs.coreutils}/bin/mktemp)"
      ${assemble}
      ${writeStep}
      ${pkgs.coreutils}/bin/chmod ${fileMode} "$TARGET"
      ${pkgs.coreutils}/bin/rm -f "$RENDERED"
    )
  '';

  # `ai.shell` / `ai.kiro.shell` → `SHELL` in Kiro's own process
  # environment. Kiro's v3 engine selects its command shell with
  # `process.env.SHELL || "/bin/sh"`, so `SHELL` is the whole knob —
  # there is no Kiro-specific variable and no config key. (`KIRO_CHAT_SHELL`
  # exists only in the Rust binary and is absent from the v3 JS bundle,
  # and the wrapper forces `--v3`, so it does not apply. Recorded so it is
  # not re-chased.)
  #
  # Everything bound for Kiro's own process environment, merged at the wrapper
  # call site in ONE place so both backends agree.
  #
  # It is deliberately NOT contributed as an `ai.kiro.environmentVariables`
  # definition, which is what it was until the collision semantics were
  # re-read: that pool is collision-checked against `ai.environmentVariables`
  # by KEY PRESENCE, so a module default for `SHELL` there turns a consumer's
  # own `ai.environmentVariables.SHELL` into a hard eval error rather than an
  # override. See `_sandboxSafeSshCommand` in lib/ai/sharedOptions.nix.
  #
  # Ordering is the contract: module defaults first, consumer pool last, so an
  # explicit entry wins. Codex and Claude resolve the same way.
  #
  # Kiro selects its shell with `process.env.SHELL || "/bin/sh"`; `||` is an
  # unset-or-empty fallback, so unlike Claude an unusable path here fails
  # loudly at spawn rather than being silently ignored.
  kiroEnvironment = {
    moduleEnvironmentVariables,
    mergedEnvironmentVariables,
    resolvedShell,
  }:
    moduleEnvironmentVariables
    // lib.optionalAttrs (resolvedShell != null) {
      SHELL = lib.getExe resolvedShell;
    }
    // mergedEnvironmentVariables;
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "kiro";
    supportedPools = [
      "context"
      "environmentVariables"
      "instructions"
      "lspServers"
      "mcpServers"
      "rules"
      "settings"
      "shell"
      "skills"
    ];
    transformers.markdown = lib.ai.transformers.kiro;
    defaults = {
      package = pkgs.ai.kiro-cli;
    };
    options = {
      # Dark-shipped upstream features, unlocked by patching the rollout
      # manifest the chat binary carries in rodata (see
      # `vu.mkKiroRolloutPatch`). The enum is EXTRACTED from that manifest
      # into the committed sidecar, never curated, so it tracks upstream.
      #
      # Why a package patch and not an env var: `tui.js` does read
      # `KIRO_ENABLED_FEATURES`, but the rust chat binary RECOMPUTES and
      # overwrites that variable before spawning bun — measured, the parent
      # held `["workflows"]` and the child received `["tangent"]`. The
      # `KIRO_ROLLOUT_FORCE_INTERNAL` / `_NIGHTLY` escape hatches do not help
      # either; `segment: "internal"` resolves off the authenticated identity.
      # So the manifest is the only client-side seam.
      #
      # Default `[]` leaves the package byte-identical to stock.
      unlockedRolloutFeatures = lib.mkOption {
        type = lib.types.listOf (lib.types.enum kiroExtracted.rolloutFeatures);
        default = [];
        example = ["workflows"];
        description = ''
          Upstream rollout features to force on by patching the kiro binary's
          embedded rollout manifest.

          These are DARK-SHIPPED and uncertified — `workflows` is documented
          upstream as "Dark-shipped at 0% until release certification is
          complete". Enabling one ships pre-release code; expect rough edges.

          Unlocking `workflows` also enables `/goal`, since the client maps the
          one flag onto both the `workflows` and `goal` session settings.
        '';
      };
      identity = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "You are Atlas, a senior systems engineer working in a terminal.";
        description = ''
          Replace the FIRST SENTENCE of the kiro-cli identity in the engine's
          system prompt. The rest of the vendor block — the prose about running
          in a terminal with no graphical editor, referring to files by path,
          and surfacing command output directly — is preserved byte-for-byte,
          because that is the part that keeps the agent behaving like a terminal
          program.

          This is the very first segment of msg0, ahead of steering, learnings
          and file tree, so it is the highest-leverage place to state what the
          agent IS.

          Mechanically: the patched engine bundle is materialized under
          `$XDG_CACHE_HOME/nix-agentic-tools/kiro-identity/` at launch and
          selected via `KIRO_KAS_SERVER_PATH`. Vendor state is never modified.
          The vendor sentence being replaced is written alongside the patch as
          `vendor-sentence.txt`.

          FAIL-OPEN: if the engine bundle cannot be resolved or the vendor
          prompt module has been restructured, the reason goes to stderr and the
          CLI launches UNPATCHED rather than refusing to start.

          May not contain a backtick or `''${` — the value is spliced into a JS
          template literal.
        '';
      };
      workflowReminder = {
        enable = lib.mkOption {
          # `null` = auto, resolved by `workflowReminderEnabled` in the backend
          # config blocks. It cannot be a computed default here: the record's
          # shared `options` attrset is built in this file's scope, where the
          # module fixpoint's `config` is not bound.
          type = lib.types.nullOr lib.types.bool;
          default = null;
          defaultText = lib.literalExpression ''
            null  # auto: true iff "workflows" is in unlockedRolloutFeatures
          '';
          description = ''
            Install a `UserPromptSubmit` hook that re-states the workflow
            orchestration contract on every turn. `null` (the default) means
            AUTO: on exactly when `workflows` is unlocked, since the reminder is
            meaningless without the feature and the feature under-elicits
            without the reminder. Set `true`/`false` to force it either way.

            Why a hook rather than more steering: when workflows are enabled the
            engine ALREADY appends its own ~4.8k-token `workflows_default` block
            to the system prompt, and msg0 is computed once on turn one and
            replayed byte-for-byte thereafter. The instruction never decays —
            ATTENTION does. A hook lands as a context message beside each
            prompt, so it buys position, not content.
          '';
        };
        text = lib.mkOption {
          type = lib.types.str;
          default = workflowReminder.defaultText;
          defaultText = lib.literalExpression "<a short pointer at the workflow contract>";
          description = ''
            The reminder appended to model context on each turn. Deliberately
            SHORT and deliberately a pointer rather than a summary: the vendor's
            full contract is already in msg0, so restating its rules here would
            fork a second source of truth that goes stale on the next engine
            bump.
          '';
        };
        includeVendorSteering = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Inject the vendor's COMPLETE `workflows_default` steering text every
            turn instead of the short reminder, extracted from the installed
            engine bundle and cached.

            Off by default because it costs roughly 4.8k tokens PER TURN (~240k
            across a 50-turn session) to repeat text the model already has in
            msg0. Turn it on only if you have measured that the short reminder
            is not enough.
          '';
        };
      };
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
      # Derived steering-file set — populated by the factory's four
      # steering emitters, consumed by the shared materializer
      # (lib/ai/materialize.nix). Internal but readable by tests and
      # consumers.
      steeringFiles = lib.mkOption {
        type = lib.types.attrsOf materializeLib.fileEntryType;
        default = {};
        internal = true;
        description = ''
          Derived steering-file set (`<name>` → `{ text | source,
          strategy }`), keyed by filename under `<configDir>/steering/`.
          Populated by the factory emitters (named/unnamed instructions,
          rules, context); delivered by the shared materializer. `text`
          is `nullOr str`, so two emitters producing the same key with
          different content is a hard eval error (equal content
          dedupes).
        '';
      };
      # Per-surface delivery strategy — the escape hatch back to store
      # symlinks (e.g. if upstream fixes kirodotdev/Kiro#9787).
      steeringStrategy = lib.mkOption {
        type = lib.types.enum ["copy" "symlink"];
        default = "copy";
        description = ''
          How steering files are delivered. `copy` (default)
          materializes REAL files via generated writers — required
          because the Kiro v3 engine (selected by `--v3`, i.e.
          `ai.kiro.v3`) silently drops symlinked steering files
          (kirodotdev/Kiro#9787), while the v2/classic engine follows
          them fine. `symlink` restores the legacy store-symlink
          delivery.

          Uninstall limitation: disabling `ai.kiro` removes the
          materializer itself, so already-materialized copies are NOT
          pruned and Kiro keeps loading them. To uninstall cleanly,
          first empty the steering surface (or set
          `steeringStrategy = "symlink"`) for one activation, THEN
          disable.
        '';
      };
      # Kiro-specific freeform settings with typed subkeys for known
      # knobs. Consumed by the settings/cli.json activation merge in
      # `hm.config` (runtime-merge via `jq -s '.[0] * .[1]'` to
      # preserve user runtime settings across rebuilds) and by the
      # static write in `devenv.config`.
      nativeSettings = lib.mkOption {
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
      # How settings/mcp.json is delivered on activation. Governs the
      # dedicated, Nix-owned mcp.json only (cli.json always merges to
      # preserve oauth); a credential url forces a real file either way.
      mcpWriteMode = lib.mkOption {
        type = lib.types.enum ["overwrite" "merge"];
        default = "overwrite";
        description = ''
          How `settings/mcp.json` is written on activation (HM) / shell
          entry (devenv). It is always a REAL file (never a store
          symlink) so a SOPS-injected secret `url` can be substituted in.

          - `overwrite` (default): the file is re-assembled from the Nix
            definition every activation and locked read-only. Nix is
            authoritative; hand edits do not survive. Equivalent to the
            old symlink-into-store guarantee, as a real file.
          - `merge`: the Nix-managed servers are deep-merged onto whatever
            is on disk (`jq '.[0] * .[1]'`, write-if-absent) and the file
            is left writeable, so hand-added servers and manual edits are
            preserved across activations.

          Both modes deliver identical content for the Nix-managed
          servers and handle secret `url`/`headers` the same way; the
          only difference is whether the on-disk file is Nix-owned
          (overwrite) or co-owned with the user (merge).
        '';
      };
      # Typed LSP server definitions for settings/lsp.json. Freeform
      # attrs-of-anything matching the legacy `attrsOf jsonFormat.type`.
      lspServers = lib.mkOption {
        type = lib.types.attrsOf aiCommon.lspServerModule;
        default = {};
        description = "Typed LSP server definitions; translated via `mkLspConfig` into settings/lsp.json on emission.";
      };
      # Env vars exported when launching kiro. In HM they're baked into
      # Baked into the symlinkJoin launcher on BOTH backends. devenv used to
      # populate its native `env` attrset instead, which exported them into
      # the project shell rather than into Kiro. `attrsOf str` — matching the
      # legacy surface.
      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Environment variables baked into the kiro launcher wrapper. Scoped to the Kiro process and the commands it spawns; never exported into the project shell.";
      };
      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        example = lib.literalExpression "with pkgs; [file which]";
        description = ''
          Packages whose binary directories are added to Kiro's PATH. The
          launcher initially prepends them while preserving the inherited
          PATH, or uses an explicit `environmentVariables.PATH` as the base
          when configured.

          This is the reliable way to expose tools inside Kiro's Linux FHS
          visibility sandbox: `/nix/store` is mounted and PATH is inherited,
          while host `/usr` is replaced by the synthesized root. Linux FHS
          startup can put its synthesized command directories ahead afterward,
          so this option supplies missing tools rather than overriding tools
          already in that root. The addition is scoped to Kiro's launcher and
          is never exported into the Home Manager session or devenv project
          shell. On Darwin, where Kiro has no FHS wrapper, the runtime-local
          prefix remains first.
        '';
      };
      # V3 next-gen agent — appends `--v3` to the top-level `kiro-cli`
      # launcher. The granular `--agent-engine`/`--mode` flags live ONLY on the
      # `chat` subcommand and are rejected by the launcher, so the launcher's
      # sole engine selector is this boolean.
      #
      # There is deliberately NO `tui` option. One existed: it injected `--tui`
      # and implied `--v3`, and that implication was load-bearing rather than
      # decorative — bare `--tui` conflicts with the chat binary's default
      # engine (v1 on 2.16.0) and the launcher supplies none of its own.
      # `--tui` selects the new TUI harness for the OLD engine; v3 already uses
      # that harness, so under v3 it is redundant, and it is going away with v3
      # regardless. Anyone who wants it on an older engine passes it on the
      # command line.
      v3 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Append `--v3` (next-generation Kiro agent) to the kiro-cli
          launcher wrapper. Applied by both backends.

          Required by `unlockedRolloutFeatures`: those features are surfaced
          only by the v3 (`kas`) engine, so unlocking them without this patches
          the binary and changes nothing observable.
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
      # exclude). Under v3 the v2 `trustedMcpTools` list is also
      # translated and merged in (see mkPermissionRules). HM-only: Kiro reads
      # permissions only from `~/.kiro/settings/` (global) or
      # `~/.kiro/workspace-roots/<hash>/`, never project `.kiro/`.
      permissions = lib.mkOption {
        type = lib.types.listOf kiroPermissionRule;
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
      # ~/.kiro or project .kiro): { name, description, model, prompt,
      # tools:[tag|"*"], mcpServers:{<name>:{command,args,env,timeout}},
      # resources:["file://..."|"skill://..."],
      # permissions:[{capability,effect,match,exclude}], welcomeMessage }.
      # Tool tags: read write shell web subagent knowledge todo_list @mcp
      # @builtin *. `.md` = YAML frontmatter + system-prompt body.
      # Default agent: `kiro-cli agent set-default <name>`.
      #
      # ALWAYS EMIT `name` — two parsers disagree about it, and the strict
      # one fails closed (measured on 2.16.0):
      #   * Rust CLI (kiro-cli-chat) parses agents as JSON ONLY and REQUIRES
      #     `name`. A `.json` file without it is rejected outright with
      #     "missing field name" on EVERY `kiro-cli` invocation, so that
      #     agent never loads. Its directory scan also SILENTLY skips `.md`
      #     agents — measured on 2.16.0, a frontmatter agent beside a valid
      #     JSON one produced no diagnostic and simply never appeared in
      #     `kiro-cli agent list`, so absence there says nothing about
      #     whether a `.md` agent is well-formed.
      #   * Node/ACP bundle (`acp-server.js`) marks `name` `.optional()` in
      #     both its JSON and frontmatter schemas ("explicit agent name that
      #     overrides filename-based ID") and falls back to the filename
      #     stem, so the IDE/ACP path keeps working and HIDES the defect.
      # When present, `name` overrides the filename-derived id, so emit it
      # equal to the `<name>` attr key unless a rename is intended.
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
        # Typed record OR the legacy raw forms. `either` tries the string/path
        # arms first; a typed record is a plain attrset, which is neither
        # `isString` nor stringLike, so the arms cannot collide. Raw JSON text
        # and paths keep working unchanged — this widening is additive.
        type = lib.types.attrsOf (
          lib.types.either
          (lib.types.either lib.types.lines lib.types.path)
          kiroAgentRecord
        );
        default = {};
        description = ''
          Agent definitions written to `<configDir>/agents/<name>.json`.

          Prefer the typed record: `name` defaults to the attribute key, so the
          field Kiro's Rust CLI requires can never be omitted, and null/empty
          fields are dropped from the emitted JSON. Raw JSON text or a path is
          still accepted and passes through untouched.
        '';
        example = lib.literalExpression ''
          {
            reviewer = {
              description = "Reviews diffs";
              prompt = ./reviewer-prompt.md;
              tools = ["read" "shell"];
            };
          }
        '';
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
      # External hooks directory. NOT symlinked — the directory's
      # top-level `*.json` files are enumerated at eval and materialized
      # as REAL files under `<configDir>/hooks` (kiro v3 drops symlinked
      # hooks), through the same manifest as the inline surfaces. See
      # `mkHookEntries` for what is and is not carried over.
      hooksDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          External directory of hook JSON files. Its top-level `*.json`
          entries are materialized as REAL files into
          `<configDir>/hooks` (not symlinked — the Kiro v3 hook scan
          drops symlinks). Subdirectories and non-`.json` entries are
          ignored; Kiro loads neither.
        '';
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
        moduleEnvironmentVariables,
        resolvedShell,
        topContext,
        ...
      }: let
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};

        steeringDir = "${cfg.configDir}/steering";
        steeringEmitters = mkSteeringEmitters {
          inherit cfg mergedInstructions mergedRules topContext;
        };

        hooksTargetDir = hookTargetDir cfg;
        hookEntries = mkHookEntries cfg;

        filteredSettings = aiCommon.filterNulls cfg.nativeSettings;
        # Kiro cli.json uses flat dot-notation keys ("chat.enableTangentMode")
        # not nested JSON. Flatten so consumers can write clean Nix:
        #   settings.chat.enableTangentMode = true;
        flatSettings = aiCommon.flattenDotKeys filteredSettings;

        # Resolve credential http headers → `${env:VAR}` placeholders in
        # mcp.json + the runtime secret-env exports (Kiro-only delivery).
        kiroSecrets = (import ./mcpSecrets.nix {inherit lib;}).renderKiroSecrets mergedServers;

        # HM's only export mechanism is the symlinkJoin wrapper, so env vars
        # ride along with the --v3/--trust-tools flag injections. Shared
        # wrapper helper (also used by the devenv backend).
        kiroPackage = wrapKiroPackage {
          inherit (cfg) extraPackages v3 trustedMcpTools;
          package = resolvePackage cfg;
          environmentVariables = kiroEnvironment {inherit moduleEnvironmentVariables mergedEnvironmentVariables resolvedShell;};
          inherit (kiroSecrets) secretEnv;
          identityMaterializer = resolveIdentityMaterializer cfg;
        };

        # Agent files, keyed by attr name. Shares `mkAgentEntry` with the devenv
        # backend so a typed record, a raw JSON string, and a path all lower
        # identically in both. (Replaces the old `mkJsonEntries`, which was
        # named for agents *and* hooks but only ever served agents — hooks go
        # through `mkAllHookFiles`.)
        agentEntries = lib.mapAttrs' (name: value:
          lib.nameValuePair "${cfg.configDir}/agents/${name}.json"
          (mkAgentEntry name value))
        cfg.agents;
      in
        lib.mkMerge ([
            # Package installation — wrapped with symlinkJoin when env
            # vars are configured. Matches the legacy wrapper shape.
            {home.packages = [kiroPackage];}
            # Per-turn workflow reminder, contributed as an ordinary typed hook
            # record so it rides the existing envelope writer rather than
            # adding a second hook path. Defining `ai.kiro.hooks` here and
            # reading it via `mkAllHookFiles` is not circular: the record
            # depends only on `workflowReminder.*` and `unlockedRolloutFeatures`.
            {ai.kiro.hooks = workflowReminderHooks cfg;}
            # Shared assertions (see mkAssertions): exclusive inline/dir
            # pairs, hook-name charset, steering-entry guards.
            {assertions = mkAssertions cfg;}
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
            # settings/mcp.json — merged MCP server pool, delivered as a
            # REAL file assembled at activation (never a store symlink) so
            # a SOPS-injected secret url can be substituted in and
            # `mcpWriteMode` can govern overwrite-vs-merge. Uniform
            # real-file across both backends dodges the symlink<->real-file
            # toggle + the devenv files.* silent skip. See mkMcpJsonScript.
            #
            # Ordered after `sops-nix` as well, because a credential url is
            # `cat`ed HERE, at activation — unlike a header secret, which the
            # launcher reads at LAUNCH, long after any secret provider has
            # run. Without this the assembly can race sops and bake an empty
            # url into a 0400 file that then looks authoritative. The dep is
            # deliberately dangling-tolerant: home-manager's topoSort drops an
            # unknown entry, so this stays secret-manager agnostic and is
            # simply inert when sops-nix is not in use (same trick as
            # `mcpRestartOnSecretRotation` in the mcp-services module).
            (lib.mkIf (mergedServers != {}) {
              home.activation.kiroMcpJson = lib.hm.dag.entryAfter ["linkGeneration" "sops-nix"] (
                mkMcpJsonScript {
                  mode = cfg.mcpWriteMode;
                  inherit (kiroSecrets) urlSecretEnv;
                  templateFile = pkgs.writeText "kiro-mcp.json" (mcpJsonText kiroSecrets.servers);
                  targetExpr = "$HOME/${cfg.configDir}/settings/mcp.json";
                }
              );
            })
            # Inline agent JSON files.
            (lib.mkIf (cfg.agents != {}) {
              home.file = agentEntries;
            })
            # External agents directory — symlinked wholesale via
            # `recursive = true` (Layout B).
            (lib.mkIf (cfg.agentsDir != null) {
              home.file."${cfg.configDir}/agents" = {
                source = cfg.agentsDir;
                recursive = true;
              };
            })
            # Hook delivery — REAL files via the shared strategy-driven
            # materializer (lib/ai/materialize.nix), NOT home.file (which
            # symlinks into /nix/store). Kiro v3 scans the hooks dir but does
            # NOT follow store symlinks (verified live on 2.13.0: global scan
            # fires real files, skips symlinks), so a symlinked hook never
            # loads. Covers BOTH hook surfaces (inline `hooks`/`hooksJson`
            # and the external `hooksDir`) through one manifest.
            #
            # Emitted whenever the module is enabled — NOT gated on a
            # non-empty hook set — so emptying the surface still prunes
            # (N→0). That gate WAS the defect: the previous writer's prune
            # sat inside `mkIf (cfg.hooks != {} || cfg.hooksJson != {})`, so
            # removing the last hook never emitted the entry, the prune never
            # ran, and every previously written hook file stayed on disk and
            # kept firing. Removing the last hook is precisely when pruning
            # matters most.
            #
            # OWNERSHIP — the explicit decision: this claims only the files
            # it WROTE (tracked per-file in the manifest), not the whole
            # directory. A hand-placed `~/.kiro/hooks/<name>.json` that this
            # module never wrote survives activation untouched, where the old
            # `rm -f "$HOOKS_DIR"/*.json` deleted it on every generation. An
            # unmanaged file colliding with a declared name is backed up
            # before being adopted (materializer clobber guard).
            {
              home.activation = materializeLib.mkHmActivation {
                files = hookEntries;
                targetDir = hooksTargetDir;
                stateSlug = materializeLib.mkStateSlug hooksTargetDir;
                inherit (pkgs) coreutils diffutils flock gnugrep;
              };
            }
            # Steering delivery — strategy-driven materializer (see
            # lib/ai/materialize.nix). Symlink entries keep exactly the
            # legacy home.file shape; copy entries are written as REAL
            # files by a two-phase activation pair (prune entryBefore
            # ["checkLinkTargets"]; write entryAfter ["linkGeneration"]).
            # Emitted whenever the module is enabled — NOT gated on
            # `steeringFiles != {}` — so emptying the surface still
            # prunes (N→0); the mkIf gates live on the emitters only.
            {
              home.file = materializeLib.mkSymlinkEntries {
                files = cfg.steeringFiles;
                targetDir = steeringDir;
              };
              home.activation = materializeLib.mkHmActivation {
                files = cfg.steeringFiles;
                targetDir = steeringDir;
                stateSlug = materializeLib.mkStateSlug steeringDir;
                inherit (pkgs) coreutils diffutils flock gnugrep;
              };
            }
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
            # (settings.json only written when cfg.nativeSettings != {}).
            # Devenv-side is unconditional (project-local, harmless).
            (lib.mkIf (filteredSettings != {}) {
              home.activation.kiroSettingsMerge = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkSettingsActivationScript {
                configFile = "${cfg.configDir}/settings/cli.json";
                settingsJson = builtins.toJSON flatSettings;
                jq = "${pkgs.jq}/bin/jq";
                inherit (pkgs) coreutils;
              });
            })
          ]
          ++ steeringEmitters);
    };
    devenv = {
      options = {};
      config = {
        cfg,
        config,
        mergedServers,
        mergedInstructions,
        mergedSkills,
        mergedRules,
        mergedLspServers,
        mergedEnvironmentVariables,
        moduleEnvironmentVariables,
        resolvedShell,
        topContext,
        ...
      }: let
        helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};

        steeringDir = "${cfg.configDir}/steering";
        steeringEmitters = mkSteeringEmitters {
          inherit cfg mergedInstructions mergedRules topContext;
        };

        hooksTargetDir = hookTargetDir cfg;
        hookEntries = mkHookEntries cfg;

        filteredSettings = aiCommon.filterNulls cfg.nativeSettings;
        flatSettings = aiCommon.flattenDotKeys filteredSettings;

        # Resolve credential http headers → `${env:VAR}` placeholders in
        # mcp.json + the runtime secret-env exports (Kiro-only delivery).
        kiroSecrets = (import ./mcpSecrets.nix {inherit lib;}).renderKiroSecrets mergedServers;

        # devenv's enterShell runs in the CALLER's cwd (direnv activates in
        # subdirectories, and the hook fires on every shell entry), so the
        # relative `${cfg.configDir}/...` writes below would land in the
        # wrong directory when the shell is entered from a subdir. Anchor
        # each fragment to the project root in a subshell — the user's
        # shell cwd stays untouched. A failed cd fails the subshell,
        # which under set -e contexts (direnv, devenv test) aborts the
        # enterShell load: deliberate fail-fast, safer than writing hook
        # files into whatever directory the caller happened to be in.
        # Same anchoring precedent as the instruction sync task
        # (dev/tasks/generate.nix) and the steering materializer task
        # (lib/ai/materialize.nix), which both `cd "$DEVENV_ROOT"`.
        anchorToDevenvRoot = body: ''
          (
            cd "$DEVENV_ROOT" || exit 1
            ${body}
          )
        '';
      in
        lib.mkMerge ([
            # Package installation — devenv projects are shell-scoped, so
            # NON-secret env exports go in the devenv `env` attrset directly
            # (below), not through the wrapper. But the `--v3`/`--trust-tools`
            # flag injection AND runtime SECRET-env injection (secretEnv must
            # cat the decrypted file at launch, not bake a static value) both
            # need the wrapper — and since 2026-08-10 so does the static env,
            # which is baked here rather than exported into the project shell.
            {
              packages = [
                (wrapKiroPackage {
                  inherit (cfg) extraPackages v3 trustedMcpTools;
                  package = resolvePackage cfg;
                  # Baked into the launcher, NOT devenv's `env` attrset. This
                  # module does not write the project shell's environment —
                  # devenv/Nix is the config path, and a variable exported
                  # shell-wide reaches the developer's own session and every
                  # other process in it, not just Kiro.
                  environmentVariables = kiroEnvironment {inherit moduleEnvironmentVariables mergedEnvironmentVariables resolvedShell;};
                  inherit (kiroSecrets) secretEnv;
                  identityMaterializer = resolveIdentityMaterializer cfg;
                })
              ];
            }
            # Per-turn workflow reminder — same contribution as the HM backend
            # (config parity; the record itself is built by the shared
            # `workflowReminderHooks`).
            {ai.kiro.hooks = workflowReminderHooks cfg;}
            # Shared assertions (see mkAssertions): exclusive inline/dir
            # pairs, hook-name charset, steering-entry guards.
            {assertions = mkAssertions cfg;}
            # Environment variables ride the launcher wrapper above, exactly
            # as they do under Home Manager. They used to be written into
            # devenv's native `env` attrset instead ("no wrapper is
            # required"), which was true of the mechanism and wrong about the
            # scope: that exports into the project shell, so every variable
            # here also reached the developer's interactive session. `SHELL`
            # made the difference concrete — it changes what tmux, editors and
            # anything else spawning `$SHELL` do — but the leak was never
            # specific to it.
            # settings/lsp.json — typed LSP server definitions.
            (lib.mkIf (mergedLspServers != {}) {
              files."${cfg.configDir}/settings/lsp.json".text =
                builtins.toJSON (lib.mapAttrs aiCommon.mkLspConfig mergedLspServers);
            })
            # settings/mcp.json — merged MCP server pool, delivered as a
            # REAL file via enterShell (anchored to $DEVENV_ROOT), matching
            # the HM activation write. See mkMcpJsonScript / mcpWriteMode.
            (lib.mkIf (mergedServers != {}) {
              enterShell = anchorToDevenvRoot (mkMcpJsonScript {
                mode = cfg.mcpWriteMode;
                inherit (kiroSecrets) urlSecretEnv;
                templateFile = pkgs.writeText "kiro-mcp.json" (mcpJsonText kiroSecrets.servers);
                targetExpr = "${cfg.configDir}/settings/mcp.json";
              });
            })
            # Inline agent JSON files.
            (lib.mkIf (cfg.agents != {}) {
              files =
                lib.concatMapAttrs (name: value: {
                  "${cfg.configDir}/agents/${name}.json" = mkAgentEntry name value;
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
            # Hook JSON files — written as REAL files, NOT devenv `files.*`
            # (which symlinks into /nix/store). ENGINE-QUALIFIED:
            # the Kiro v3 engine (Node; its directory scan keeps only
            # `entry.isFile()` entries) silently DROPS symlinked leaf files —
            # hooks and steering alike — while the v2/classic engine (Rust)
            # follows leaf symlinks fine. The shipped default IS v3 (this
            # factory's wrapper injects `--v3`), so symlinked delivery is
            # dead on arrival for v3 users. Upstream: kirodotdev/Kiro#9787
            # (confirmed live on 2.13.0). See the kiro-v3-hooks-workspace-local
            # finding + docs/plans/kiro-cli-auto-memory.md.
            #
            # Steering therefore no longer ships symlinks by default: the
            # emitters populate `ai.kiro.steeringFiles` and the shared
            # materializer delivers per the entry's `strategy` field ("copy"
            # default materializes real files; "symlink" restores the legacy
            # shape). Hooks ride the SAME materializer (copy-only — see
            # `mkHookEntries`), which is what gives them HM parity by
            # construction.
            #
            # Emitted whenever the module is enabled — NOT gated on a
            # non-empty hook set — so emptying the surface still prunes
            # (N→0). That gate WAS the defect: the previous enterShell
            # fragments carried their prune inside
            # `mkIf (cfg.hooks != {} || cfg.hooksJson != {})` and
            # `mkIf (cfg.hooksDir != null)`, so removing the last hook never
            # emitted the fragment, the prune never ran, and every previously
            # written hook file stayed in `.kiro/hooks/` and kept firing.
            #
            # OWNERSHIP — the explicit decision, matching HM: this claims
            # only the files it WROTE (tracked per-file in the manifest under
            # $DEVENV_STATE), not the whole directory. A hand-placed
            # `.kiro/hooks/<name>.json` survives; the old
            # `rm -f <dir>/*.json` deleted it on every shell entry.
            #
            # The task `cd`s to $DEVENV_ROOT itself (materialize.nix), which
            # is the same anchoring the retired enterShell fragments needed:
            # shell entry runs in the CALLER's cwd because direnv activates
            # in subdirectories.
            {
              tasks."ai:kiro:materialize-hooks" = materializeLib.mkDevenvTask {
                files = hookEntries;
                targetDir = hooksTargetDir;
                stateSlug = materializeLib.mkStateSlug hooksTargetDir;
                hasFiles = config.files != {};
                inherit (pkgs) coreutils diffutils flock gnugrep;
              };
              enterTest = materializeLib.mkEnterTest {
                app = "kiro";
                files = hookEntries;
                targetDir = hooksTargetDir;
              };
            }
            # Steering delivery — strategy-driven materializer (parity
            # with HM; see lib/ai/materialize.nix). Symlink entries keep
            # exactly the legacy files.* shape; copy entries are written
            # as REAL files by the `ai:kiro:materialize-steering` task
            # (prune+write, ordered before devenv:enterShell and —
            # conditionally, the runner hard-errors on dangling refs —
            # before devenv:files). Emitted whenever the module is
            # enabled so emptying the surface still prunes (N→0). The
            # enterTest fragment is the consumer backstop: every copy
            # entry must exist as a real file or `devenv test` fails.
            {
              files = materializeLib.mkSymlinkEntries {
                files = cfg.steeringFiles;
                targetDir = steeringDir;
              };
              tasks."ai:kiro:materialize-steering" = materializeLib.mkDevenvTask {
                files = cfg.steeringFiles;
                targetDir = steeringDir;
                stateSlug = materializeLib.mkStateSlug steeringDir;
                hasFiles = config.files != {};
                inherit (pkgs) coreutils diffutils flock gnugrep;
              };
              enterTest = materializeLib.mkEnterTest {
                app = "kiro";
                files = cfg.steeringFiles;
                targetDir = steeringDir;
              };
            }
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
          ]
          ++ steeringEmitters);
    };
  }

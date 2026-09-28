# Kimchi-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kimchi AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Kimchi has distinct user and project config namespaces. Home Manager writes
# ~/.config/kimchi/{config.json,harness/}; devenv writes only Kimchi's native
# project paths under the repository root. Settings are Nix's: every JSON file
# is a read-only copy, except the HM user config.json, a state file Kimchi also
# writes (device id, migration state, acknowledgements) whose declared leaves
# are reconciled. The remaining files are immutable and symlink-readable.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  sharedHooks = lib.ai.hooks;
  # Native option types, project-tier keys and environment names, all read
  # from the committed sidecar (never passthru.extracted: that is IFD).
  sidecar = import ./extracted.nix {
    inherit lib pkgs;
    extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
  };

  # pi 0.85.1 derives CONFIG_DIR_NAME from Kimchi's packaged piConfig.configDir.
  # That fixed project namespace is independent of ai.kimchi.configDir, which
  # selects the Home Manager output root.
  projectHarnessDir = ".config/kimchi/harness";
  projectContextFilename = "AGENTS.md";
  # The user harness directory, and the context file in it Home Manager
  # writes; shared by the emitter and `contentTargets`.
  userHarnessDir = cfg: "${cfg.configDir}/harness";
  userContextPath = cfg: "${userHarnessDir cfg}/${cfg.context.filename}";
  # Home Manager's Auto model default: below `mkDefault` (1000), so a
  # consumer's own key-level mkDefault wins, and above the option default
  # (1500), which a non-null value at the same priority would conflict with.
  autoModelPriority = 1200;

  # Home Manager defaults the model to Kimchi's Auto router and owns the
  # choice, instead of leaving it to Kimchi 1.1.37, which installs Auto as
  # the saved default itself once per install: on a fresh main-session launch
  # with no --model, on a `kimchi-dev` model that is not already Auto, when
  # the catalog advertises `kimchi-dev/auto` and the user harness
  # settings.json lacks `autoDefaultApplied: true`
  # (src/extensions/auto-model/index.ts:253-291). It persists
  # defaultProvider, defaultModel and the marker through writeJson
  # (src/config.ts:831-842), which renames a temporary over the file
  # (src/config/json.ts:154-159): that silently replaces a store symlink in a
  # writable directory, and in a read-only one the temporary write throws, so
  # the session stays on Auto and retries every launch.
  #
  # A module of the option TYPE, not a definition of the option: an outer
  # definition would sit at normal priority, and the outer option's
  # filterOverrides would drop a consumer's whole-attrset
  # `harnessSettings = lib.mkDefault {…}` before the submodule saw it. Here
  # every consumer definition, whole-attrset or per key, reaches the
  # submodule and competes per key.
  #
  # The pair sits at `autoModelPriority` and is coupled: a consumer who
  # declares either half at a priority below 1200 (mkDefault and stronger,
  # null included) gets neither half from here, so a lone `defaultModel` on
  # another provider never pairs with `kimchi-dev`. Weaker declarations
  # (mkOptionDefault, mkOverride above 1200) lose to the default, and
  # mkOverride 1200 is a conflict error. `highestPrio` reads only definition
  # priorities, never values, so the test cannot recurse.
  #
  # An account whose catalog lacks `auto` still starts: pi 0.85.1's
  # findInitialModel skips a saved default the registry does not hold and
  # falls back, silently, to the model it picks when no default is declared
  # (dist/core/model-resolver.js:501-529). Any saved default, Auto included,
  # also turns off the global `multiModel` default on a fresh launch whose
  # model is not on `kimchi-dev` (auto-model/index.ts:104-106,255-259), so
  # such an account loses multi-model, and `multiModel = true` takes effect
  # only with `defaultModel = null`.
  #
  # A saved Auto default is not a lock. Kimchi persists a startup `--model`
  # given over a routed Auto default (auto-model/index.ts:215-229), as it
  # does `/model` set-default, the set_model tool and ACP model changes, into
  # the writable user file; that choice holds until the next activation
  # restores the owned leaves.
  #
  # The marker stays declared, at `mkDefault`, for a consumer who declares a
  # non-Auto `kimchi-dev` model or nulls the pair: without it Kimchi would
  # replace that choice. null and false differ: null hands the marker back to
  # Kimchi (Auto installs once), while false re-arms the install after every
  # activation, because Kimchi reads only `=== true`, writes true, and
  # activation restores the owned false.
  #
  # Home Manager only: Kimchi reads the marker from the user file alone
  # (src/config.ts:22,812-814), devenv rejects user-scope harness keys, and a
  # project `defaultModel` would put every devenv Kimchi behind project trust
  # and the exact-cwd launch guard.
  hmHarnessDefaults = {options, ...}: let
    consumerDeclared = lib.any (name: options.${name}.highestPrio < autoModelPriority) ["defaultModel" "defaultProvider"];
    autoDefault = value:
      lib.mkOverride autoModelPriority (
        if consumerDeclared
        then null
        else value
      );
  in {
    config = {
      autoDefaultApplied = lib.mkDefault true;
      defaultModel = autoDefault "auto";
      defaultProvider = autoDefault "kimchi-dev";
      # A read-only settings.json can no longer take the values Kimchi seeds
      # at launch (src/cli.ts:512-551): hideThinkingBlock and quietStartup are
      # Kimchi's own first-launch values; enableInstallTelemetry, retry and
      # theme close the gaps the review found in the seed (lastChangelogVersion
      # is left undeclared, so Kimchi's install-telemetry report is suppressed
      # via enableInstallTelemetry instead of a hardcoded version string).
      enableInstallTelemetry = lib.mkDefault false;
      hideThinkingBlock = lib.mkDefault true;
      quietStartup = lib.mkDefault true;
      retry = lib.mkDefault {
        provider = {
          maxRetries = 0;
          timeoutMs = 600000;
        };
      };
      theme = lib.mkDefault "kimchi-minimal";
    };
  };

  # config.json's HM-only defaults: Kimchi's first-launch values, seeded only
  # when the file does not already exist (src/cli.ts:512-541), which never
  # happens under Home Manager's always-present copy. `region` defaults to
  # null (not "us"): the launcher only emits KIMCHI_REGION when a value is
  # declared, so an unset default here leaves an EU login's region alone
  # instead of forcing every account to "us".
  hmSettingsDefaults = {
    config = {
      preferences.hideTips = lib.mkDefault false;
      region = lib.mkDefault null;
      skillPaths = lib.mkDefault [".config/kimchi/harness/skills" ".pi/agent/skills" ".claude/skills"];
      # Reconsidered but kept: switching this off by default would turn
      # telemetry off for every Home Manager user without an explicit choice.
      # A user who opted out in-app is still reset by the next switch; see
      # the kimchi-factory.md BREAKING CHANGE note.
      telemetry.enabled = lib.mkDefault true;
    };
  };

  # Both native files are typed from packages/kimchi/extracted.json by
  # ./extracted.nix. The submodules are closed: a key Kimchi does not read is
  # an unknown-option error, not bytes nothing reads. Declared per backend
  # because only Home Manager's harness type carries `hmHarnessDefaults`.
  nativeOptions = backend: let
    isHm = backend == "hm";
  in {
    settings = lib.mkOption {
      type = lib.types.submodule ([{options = sidecar.settingsOptions;}] ++ lib.optional isHm hmSettingsDefaults);
      default = {};
      description =
        ''
          Kimchi `config.json`, typed from the keys the pinned Kimchi reads
          (packages/kimchi/extracted.json). Reconciled by leaf in
          <configDir>/config.json on Home Manager activation or
          .kimchi/config.json on devenv shell entry. Devenv rejects keys Kimchi
          reads only from the user file. `apiKey` has no option here: it is a
          secret, delivered by `ai.kimchi.apiKey`.
        ''
        + lib.optionalString isHm ''
          Home Manager defaults `preferences.hideTips = false`,
          `skillPaths` to where `ai.*` delivers skills, and
          `telemetry.enabled = true`, Kimchi's own first-launch values, at
          `mkDefault`; an in-app change to a declared leaf is reset on every
          switch. `region` defaults to null, not "us": it is only emitted as
          `KIMCHI_REGION` when declared, so an unset default leaves a login's
          own region alone.
        '';
    };

    harnessSettings = lib.mkOption {
      type = lib.types.submodule ([{options = sidecar.harnessSettingsOptions;}] ++ lib.optional isHm hmHarnessDefaults);
      default = {};
      description =
        ''
          Kimchi and pi harness `settings.json`, typed from the keys the pinned
          Kimchi and pi read (packages/kimchi/extracted.json). Reconciled by
          leaf in <configDir>/harness/settings.json on Home Manager activation
          or .config/kimchi/harness/settings.json on devenv shell entry. Kimchi
          mutates the user file at runtime, so both backends preserve unowned
          settings and retract retired leaves.
        ''
        + lib.optionalString isHm ''
          Home Manager defaults the model to Kimchi's Auto router,
          `defaultProvider = "kimchi-dev"` and `defaultModel = "auto"`, at
          priority 1200, below `mkDefault`. Declaring either key at `mkDefault`
          or stronger, null included, replaces both; a weaker declaration loses
          to the default. Any saved default, Auto included, turns off Kimchi's
          global `multiModel` default on a fresh launch whose model is not on
          `kimchi-dev`, so `multiModel = true` needs `defaultModel = null`; an
          account whose catalog lacks Auto gets the model Kimchi picks when
          none is declared, with multi-model off. The default is not a lock: a
          `kimchi --model X` launch, `/model` set-default or an ACP model change
          persists into the writable user file until the next activation. Home
          Manager also declares `autoDefaultApplied = true`,
          `hideThinkingBlock = true`, `quietStartup = true`,
          `enableInstallTelemetry = false`, `theme = "kimchi-minimal"` and a
          `retry` provider block (timeoutMs 600000, maxRetries 0) at
          `mkDefault`: Kimchi's own first-launch seed, which its first-run
          seeding never runs against an always-present Home Manager file.
        '';
    };
  };

  # Kimchi 1.1.36 reads `region` and `telemetry.enabled` from its environment
  # ahead of config.json (KIMCHI_REGION, src/config.ts:193;
  # KIMCHI_TELEMETRY_ENABLED, :504-506). The launcher sets both from these
  # leaves, so the Nix value wins at read time even after Kimchi rewrites the
  # file, and devenv delivers them this way alone: a project config.json does
  # not honor either key.
  envShadowedSettings = settings: {
    inherit (settings) region;
    telemetryEnabled =
      if settings.telemetry == null
      then null
      else settings.telemetry.enabled;
  };
  # What a project .kimchi/config.json carries: the declaration without the
  # environment-shadowed leaves.
  projectSettings = cfg:
    aiCommon.filterNulls (lib.recursiveUpdate cfg.native.settings {
      region = null;
      telemetry.enabled = null;
    });

  # Kimchi 1.1.30's lifecycle events, FULL_COMMAND_HOOK_EVENTS
  # (src/extensions/hook-adapters/discovery.ts:29-50). Every portable event
  # except PermissionRequest is among them, and the reader skips an event
  # outside this list without a word (:131).
  hookEvents = [
    "MessageEnd"
    "MessageStart"
    "ModelSelect"
    "Notification"
    "PostCompact"
    "PostToolBatch"
    "PostToolUse"
    "PostToolUseFailure"
    "PreCompact"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "StopFail"
    "SubagentStart"
    "SubagentStop"
    "TaskCompleted"
    "TurnStart"
    "UserBash"
    "UserPromptSubmit"
  ];
  # Shared groups first, Kimchi's own appended, restricted to the events
  # Kimchi reads. The one portable event it lacks can only arrive through the
  # shared pool, which has no per-runtime remedy, so it is dropped silently
  # (see the root-pool rule in lib/ai/delivery-warnings.nix).
  projectHooksFor = {
    cfg,
    topHooks,
  }:
    lib.filterAttrs (event: blocks: builtins.elem event hookEvents && blocks != [])
    (sharedHooks.merge topHooks cfg.hooks);
  hasHookHandlers = hooks: lib.any (lib.any (block: block.hooks != [])) (builtins.attrValues hooks);

  # The launcher both install hooks share: the merged environment, the
  # runtime secret export and, on devenv, the exact-cwd guard.
  mkPrep = {
    cfg,
    launcherEnvironment,
    requiredProjectRoot ? null,
  }: let
    # Non-secret env vars — baked into the wrapper via `--set`.
    shadowed = envShadowedSettings cfg.native.settings;
    kimchiEnvVars =
      lib.optionalAttrs cfg.noUpdateCheck {${sidecar.environmentName "KIMCHI_NO_UPDATE_CHECK"} = "1";}
      // lib.optionalAttrs (shadowed.region != null) {${sidecar.environmentName "KIMCHI_REGION"} = shadowed.region;}
      # Any value but `0` or `false` turns telemetry on.
      // lib.optionalAttrs (shadowed.telemetryEnabled != null) {
        ${sidecar.environmentName "KIMCHI_TELEMETRY_ENABLED"} =
          if shadowed.telemetryEnabled
          then "1"
          else "0";
      };
    # The builder's `launcherEnvironment` keeps module defaults (e.g. the
    # sandbox-safe GIT_SSH_COMMAND) under the consumer's pool, as for every
    # harness. `kimchiEnvVars` stays last: those are derived from typed
    # options, not free-form entries.
    effectiveEnvVars = launcherEnvironment // kimchiEnvVars;

    # The Cast AI key is a secret: read it from its decrypted file (or
    # helper) at launch via the repo's shared credential snippet, so it is
    # never serialized into the world-readable /nix/store. Same mechanism
    # the MCP servers use (lib/mcp.nix); sops-nix / agenix agnostic.
    credSnippet =
      if cfg.apiKey != null
      then mcpLib.mkCredentialsSnippet pkgs {apiKey.envVar = sidecar.environmentName "KIMCHI_API_KEY";} {inherit (cfg) apiKey;}
      else "";

    # Kimchi resolves project config, MCP servers, and harness settings from
    # process.cwd() exactly. Changing cwd here would also change the directory
    # seen by Kimchi's tools, so reject descendant launches instead.
    exactCwdGuard = lib.optionalString (requiredProjectRoot != null) ''
      kimchi_project_root=${lib.escapeShellArg requiredProjectRoot}
      if [ "$(${pkgs.coreutils}/bin/realpath -- "$PWD")" != "$(${pkgs.coreutils}/bin/realpath -- "$kimchi_project_root")" ]; then
        printf '%s\n' "Kimchi project files are configured at $kimchi_project_root; run kimchi from that devenv root." >&2
        exit 1
      fi
    '';

    # wrapProgram args: `--set` for non-secret env, `--run` for the
    # runtime secret export. Joined with a single space on the continued
    # line — never a backslash-newline, which breaks multi-arg wrapping.
    wrapArgs =
      lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") effectiveEnvVars
      ++ lib.optional (exactCwdGuard != "") "--run ${lib.escapeShellArg exactCwdGuard}"
      ++ lib.optional (credSnippet != "") "--run ${lib.escapeShellArg credSnippet}";

    # Not `lib.ai.mkLauncher`: that one writes `wrapProgram` on one line, and
    # moving this continued form onto it would change the wrapper's store path.
    wrappedPackage = pkgs.symlinkJoin {
      name = "kimchi-wrapped";
      paths = [cfg.package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = lib.optionalString (wrapArgs != []) ''
        wrapProgram $out/bin/kimchi \
          ${lib.concatStringsSep " " wrapArgs}
      '';
    };
  in {
    package =
      if wrapArgs != []
      then wrappedPackage
      else cfg.package;
  };
  # Both backends install the same prepared wrapper (env + the runtime secret,
  # which is cat'd at launch so it never enters the store). Handed to the
  # shared transform's `installPackage` hook, which owns the `home.packages` /
  # `packages` lowering. Devenv adds the exact-cwd guard when it writes any
  # project file Kimchi resolves from the working directory.
  kimchiInstallPackage = {
    backend,
    cfg,
    config,
    launcherEnvironment,
    mergedAgents,
    mergedServers,
    topHooks,
    ...
  }: let
    hasExactCwdProjectFiles =
      projectSettings cfg
      != {}
      || aiCommon.filterNulls cfg.native.harnessSettings != {}
      || mergedServers != {}
      || mergedAgents != {}
      || aiCommon.filterNulls cfg.permissions != {}
      || hasHookHandlers (projectHooksFor {inherit cfg topHooks;});
  in
    (mkPrep {
      inherit cfg launcherEnvironment;
      requiredProjectRoot =
        if backend == "devenv" && hasExactCwdProjectFiles
        then config.devenv.root
        else null;
    }).package;
  # One delivery description for both backends. The two former callback bodies
  # were near-duplicates: they differed only in which native sink each wrote,
  # which is exactly the decision the delivery layer now makes from the
  # consumer facts below.
  kimchiDelivery = {
    backend,
    cfg,
    config,
    hasMergedContext,
    mergedAgents,
    mergedContext,
    mergedEnvironmentVariables,
    mergedServers,
    mergedSkills,
    resolvedSettings,
    topHooks,
    ...
  }: let
    contextEntry = aiCommon.contentFileEntry mergedContext;
    filteredSettings = aiCommon.filterNulls cfg.native.settings;
    filteredProjectSettings = projectSettings cfg;
    filteredHarnessSettings = aiCommon.filterNulls cfg.native.harnessSettings;
    filteredPermissions = aiCommon.filterNulls cfg.permissions;
    gitTokens = lib.filterAttrs (_: token: token != null) cfg.gitTokens;
    isDevenv = backend == "devenv";
    harness =
      if isDevenv
      then projectHarnessDir
      else userHarnessDir cfg;
    # The project directory for Kimchi's own files.
    projectDir = ".kimchi";
    # Where Kimchi reads MCP servers and skills: a trusted project's own
    # directory, or the user harness.
    mcpAndSkillsDir =
      if isDevenv
      then projectDir
      else harness;
    # Kimchi 1.1.30 hard-codes the user file to
    # resolve(homedir(), ".config", "kimchi", "harness", "permissions.json")
    # (src/extensions/permissions/config.ts:35), so unlike the rest of the
    # harness it does not follow configDir even under a package override.
    permissionsDir =
      if isDevenv
      then projectDir
      else ".config/kimchi/harness";
    # Kimchi 1.1.30 loads `<agentDir>/agents/*.md` and a trusted project's
    # `.kimchi/agents/*.md` (src/extensions/agents/personas/custom-agents.ts:21-35).
    agentsDir =
      if isDevenv
      then "${projectDir}/agents"
      else "${harness}/agents";
    userScopeOnlyHarnessSettings = lib.intersectLists sidecar.userScopeHarnessKeys (builtins.attrNames filteredHarnessSettings);
    userScopeConfigSettings = lib.intersectLists sidecar.userScopeConfigKeys (builtins.attrNames filteredProjectSettings);
    fixedEnvironmentVariables = builtins.attrNames (builtins.intersectAttrs sidecar.fixedEnvironmentVariables (lib.filterAttrs (_: value: value != null) mergedEnvironmentVariables));
    # Home Manager's agents ledger identity predates project-path delivery and
    # is an upgrade contract: keep hashing configDir so a new generation
    # retracts files owned before this port. Devenv keys its ledger by the
    # actual project path.
    agentsLedger = "materialize/kimchi-agents-${builtins.hashString "sha256" (
      if isDevenv
      then agentsDir
      else cfg.configDir
    )}.manifest";
    # One directory ledger per directory the settings copies land in, keyed
    # by that directory: own refuses two live targets on one path.
    filesLedger = dir: "materialize/kimchi-files-${builtins.hashString "sha256" dir}.manifest";
    # A read-only copy owned by the `kimchiFiles` writer, in the directory
    # ledger of the directory it lands in. Home Manager owns every user-global
    # file whatever is declared; devenv claims a project file only when
    # something is declared.
    settingsCopy = path: fields:
      lib.nameValuePair path (lib.mkIf (!isDevenv || fields.content.value != {}) ({
          entry = "kimchiFiles";
          format = "json";
          ledger = filesLedger (dirOf path);
          method = "copy-ro";
        }
        // fields));
    relativeTrustKeys = builtins.filter (key: !(lib.hasPrefix "/" key)) (builtins.attrNames cfg.projectTrust);
    # A semantic record's `tools` names Claude/Copilot tools (`Read`), while
    # Kimchi compares its own lowercase builtins exactly
    # (src/extensions/agents/personas/agent-types.ts:12). Dropping the list
    # would widen the agent to every tool, and translating it would fail
    # silently on the first unmatched name, so the record is rejected instead.
    toolAgents = builtins.attrNames (lib.filterAttrs (_: value: lib.ai.agent.isSemantic value && (value.tools or null) != null && value.tools != []) mergedAgents);
    # Root Markdown is written for Claude and Copilot. Kimchi reads the same
    # file differently: `name:` is ignored, `model: sonnet` becomes a Kimchi
    # model id, and `tools:` is matched against its lowercase builtins
    # (custom-agents.ts:52-85,125-132). Only a portable record crosses over;
    # Markdown under ai.kimchi.agents is Kimchi's own.
    rootMarkdownAgents = builtins.attrNames (lib.filterAttrs (name: value: value != null && !(lib.ai.agent.isSemantic value) && !(cfg.agents ? ${name})) config.ai.agents);
    # Git tokens are secrets with no environment input: Kimchi reads them only
    # from the user config.json (src/extensions/teleport/provisioning/
    # git-token.ts). So the renderer reads each one from its file or helper
    # when the writer runs and merges it into the declaration; the store holds
    # only the path. Each export lives in the renderer's own process.
    tokenVars = lib.listToAttrs (lib.imap0 (index: host: lib.nameValuePair host {envVar = "kimchi_git_token_${toString index}";}) (builtins.attrNames gitTokens));
    userConfigContent =
      if gitTokens == {}
      then {value = filteredSettings;}
      else {
        run = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${mcpLib.mkCredentialsSnippet pkgs tokenVars gitTokens}
          exec ${pkgs.jq}/bin/jq -n --slurpfile declared ${pkgs.writeText "kimchi-config.json" (builtins.toJSON filteredSettings)} ${lib.escapeShellArg "$declared[0] * {gitTokens: {${lib.concatStringsSep ", " (lib.mapAttrsToList (host: var: "${builtins.toJSON host}: env.${var.envVar}") tokenVars)}}}"}
        '';
      };
  in
    lib.mkMerge [
      {
        assertions =
          [
            {
              assertion = fixedEnvironmentVariables == [];
              message = ''
                ai.kimchi environment variables ${lib.concatStringsSep ", " fixedEnvironmentVariables} are overwritten by Kimchi before anything reads them (${lib.concatMapStringsSep "; " (name: "${name}: ${sidecar.fixedEnvironmentVariables.${name}}") fixedEnvironmentVariables}), so a value set here is never read.
                Remove it from ai.kimchi.environmentVariables, or tombstone a root ai.environmentVariables entry with ai.kimchi.environmentVariables.<name> = null.
              '';
            }
            {
              assertion = toolAgents == [];
              message = "ai.kimchi agents ${lib.concatStringsSep ", " toolAgents} carry a `tools` allowlist in Claude/Copilot tool names, which Kimchi does not read (it matches its lowercase builtins read, bash, edit, write, grep, find, ls exactly). Set ai.kimchi.agents.<name> to native Kimchi Markdown with its own `tools:` line, or to null.";
            }
            {
              assertion = rootMarkdownAgents == [];
              message = "ai.agents ${lib.concatStringsSep ", " rootMarkdownAgents} are Markdown written for Claude/Copilot, which Kimchi misreads (`name:` ignored, `model:` taken as a Kimchi model id, `tools:` matched against its lowercase builtins). Set ai.kimchi.agents.<name> to native Kimchi Markdown, a portable { description, instructions } record, or null.";
            }
          ]
          ++ lib.optional (!isDevenv) {
            assertion = relativeTrustKeys == [];
            message = "ai.kimchi.projectTrust keys must be absolute paths; Kimchi looks trust up by the realpath of the working directory, so ${lib.concatStringsSep ", " relativeTrustKeys} could never match.";
          }
          # Explicit exclusions, not silent no-ops: these live only under the
          # user's HOME, and devenv writes only inside the project. Without
          # Home Manager those user files are Kimchi's own.
          ++ lib.optionals isDevenv [
            {
              assertion = cfg.projectTrust == {};
              message = ''
                ai.kimchi.projectTrust is user scope: Kimchi reads project trust only from ~/.config/kimchi/harness/trust.json, so that a project cannot trust itself, and devenv writes only inside the project.
                Set it with Home Manager. Without Home Manager that file is Kimchi's own, and its trust prompt saves the decision there.
              '';
            }
            {
              assertion = gitTokens == {};
              message = ''
                ai.kimchi.gitTokens is user scope: Kimchi reads git tokens only from ~/.config/kimchi/config.json and has no environment input for them, and devenv writes only inside the project.
                Set it with Home Manager. Without Home Manager that file is Kimchi's own, and Kimchi saves the tokens it asks for there.
              '';
            }
            {
              assertion = userScopeConfigSettings == [];
              message = ''
                ai.kimchi.native.settings contains config.json keys Kimchi reads only from user scope: ${lib.concatStringsSep ", " userScopeConfigSettings}.
                Kimchi merges only its project-honored keys from .kimchi/config.json. Set these with Home Manager; without it, the user config.json is Kimchi's own. (`region` and `telemetry.enabled` are accepted here: the launcher passes them as KIMCHI_REGION and KIMCHI_TELEMETRY_ENABLED.)
              '';
            }
            {
              assertion = userScopeOnlyHarnessSettings == [];
              message = ''
                ai.kimchi.native.harnessSettings contains settings Kimchi reads only from user scope: ${lib.concatStringsSep ", " userScopeOnlyHarnessSettings}.
                Set these with Home Manager, which owns ~/.config/kimchi/harness/settings.json. Without Home Manager that file is Kimchi's own.
              '';
            }
          ];
        # A directory of whole files; Home Manager needs the second entry
        # that deletes a retired real file before checkLinkTargets.
        ai.kimchi.activation.kimchiAgents = {
          entry = {
            devenv = "ai:kimchi:agents";
            hm = "kimchiAgents";
          };
          ledgers.${agentsLedger} = {
            codec = "dir";
            path = agentsDir;
          };
          pruneEntry = "kimchiAgentsPrune";
        };
        # Every settings copy, one directory ledger per directory. Declared
        # unconditionally: an empty ledger is how a retired copy is removed.
        # The directories stay writable, because Kimchi keeps state and locks
        # beside these files.
        ai.kimchi.activation.kimchiFiles = {
          entry = {
            devenv = "ai:kimchi:files";
            hm = "kimchiFiles";
          };
          ledgers = lib.listToAttrs (map (dir:
            lib.nameValuePair (filesLedger dir) {
              codec = "dir";
              path = dir;
            }) (lib.unique [harness mcpAndSkillsDir permissionsDir]));
          pruneEntry = "kimchiFilesPrune";
        };
      }

      # pi 0.85.1's ThinkingLevel is a superset of the normalized enum and
      # pi reads `defaultThinkingLevel` from the merged user and project
      # harness settings, so the lowering is lossless on both backends. It is
      # a default: an explicit native harness value wins.
      (lib.mkIf (resolvedSettings.reasoningEffort != null) {
        ai.kimchi.native.harnessSettings.defaultThinkingLevel = lib.mkDefault resolvedSettings.reasoningEffort;
      })

      # The user config.json is a state file: Kimchi renames its own writes
      # over it at every launch (`deviceId`, src/posthog-device.ts:21-31;
      # `migrationState`, src/cli.ts:398-423) and on acknowledgements
      # (onboarding and survey `seenAt`). A read-only copy would be replaced on
      # nearly every run, so Home Manager owns the declared leaves inside it and
      # leaves those keys to Kimchi. Devenv's project file is a copy below:
      # Kimchi never writes it.
      (lib.mkIf (!isDevenv) (lib.mkMerge [
        (helpers.mkReconciledDocument {
          content = userConfigContent;
          format = "json";
          # Upgrade contract: ownership recorded by earlier generations hangs
          # off this name.
          ledger = "json-settings/kimchi-config-${builtins.hashString "sha256" cfg.configDir}.json";
          path = "${cfg.configDir}/config.json";
          runtime = "kimchi";
          writer = "kimchiConfigMerge";
        })
        # Git tokens are read at activation, after the secret provider.
        {ai.kimchi.activation.kimchiConfigMerge.after = ["files" "secrets"];}
        # The user config.json holds `apiKey` and `gitTokens`. The merge writer
        # keeps an existing file's mode whether or not it rewrites it, so this
        # is the only thing that narrows a file an earlier generation widened to
        # 0644, with or without settings.
        {
          ai.kimchi.activation.kimchiConfigMode = helpers.mkCredentialModeWriter {
            inherit (pkgs) coreutils;
            path = "${cfg.configDir}/config.json";
          };
        }
      ]))

      # Every other JSON file is configuration and a read-only copy. Kimchi's
      # writers either rename a temporary over the path (MCP edits, the setup
      # wizard, `writeConfigSetting`: src/config/json.ts:154-160), which would
      # replace a store symlink, or write in place (pi's settings store,
      # `/permissions save`), which fails on the copy but is caught. The next
      # activation or shell entry backs a replaced file up and restores the
      # declaration, so in-app changes do not persist. trust.json is NOT here:
      # pi's in-place trust write is uncaught and exits the process, so it is
      # reconciled by leaf below instead.
      {
        ai.kimchi.files = lib.listToAttrs (
          [
            (settingsCopy "${harness}/settings.json" {content.value = filteredHarnessSettings;})
            (settingsCopy "${mcpAndSkillsDir}/mcp.json" {
              content.value = lib.optionalAttrs (mergedServers != {}) {
                mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
              };
            })
            (settingsCopy "${permissionsDir}/permissions.json" {content.value = filteredPermissions;})
          ]
          # Kimchi warns once per launch when a group or other can read a
          # config.json (src/config.ts:390-403,533), so the project copy is
          # owner-only.
          ++ lib.optional isDevenv (settingsCopy "${projectDir}/config.json" {
            content.value = filteredProjectSettings;
            mode = "0400";
          })
        );
      }

      # trust.json — a read-only copy makes pi exit at startup: every trust
      # prompt answer ("Trust", "Trust parent folder" and "Do not trust", not
      # only the session-only ones) goes through `writeTrustFile`, a
      # `writeFileSync` in place (dist/core/trust-manager.js:94-104,187-200),
      # and nothing between there and pi's entrypoint catches the error, so a
      # 0444 file makes kimchi print it and `process.exit(1)`
      # (src/cli.ts:830-839). So trust decisions are reconciled by leaf, like
      # the user config.json, instead of copied: a declared
      # `ai.kimchi.projectTrust` entry is Nix-owned, and a decision answered
      # at the prompt is unowned and survives. The renderer canonicalizes each
      # key when the writer runs (see project-trust.py), which is why this
      # document declares `run` rather than `value`. Declared even when empty,
      # so removing the last entry retracts a previously declared one. Home
      # Manager only: devenv rejects the option in the assertions above.
      (lib.mkIf (!isDevenv) (helpers.mkReconciledDocument {
        content.run = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exec ${pkgs.python3}/bin/python3 ${./project-trust.py} ${pkgs.writeText "kimchi-project-trust.json" (builtins.toJSON cfg.projectTrust)}
        '';
        entry = "kimchiProjectTrustMerge";
        format = "json";
        ledger = "json-settings/kimchi-trust-${builtins.hashString "sha256" harness}.json";
        # pi takes proper-lockfile's `<path>.lock` around every trust read and
        # rewrite (acquireTrustLockSync, withTrustFileLock:
        # dist/core/trust-manager.js:105-142,187-200), so the reconciler takes
        # the same lock rather than racing a prompt answered during a switch.
        lock = "${harness}/trust.json.lock";
        path = "${harness}/trust.json";
        runtime = "kimchi";
        writer = "kimchiProjectTrustMerge";
      }))

      # User harness context stays runtime-owned. Project context joins the
      # shared repository AGENTS.md through the record's `sharedAgentsMd`.
      (lib.mkIf (hasMergedContext && !isDevenv) {
        ai.kimchi.files.${userContextPath cfg} = contextEntry;
      })

      # agents/<name>.md — one read-only copy per agent. Kimchi's /agents
      # Edit, Disable and Enable writeFileSync the file in place, and Create
      # and Eject write new ones beside it (src/extensions/agents/index.ts:
      # 2556-2874): an edit of a declared agent fails, and a file Kimchi
      # created is an unowned sibling that is never touched.
      {
        ai.kimchi.files = lib.mapAttrs' (name: value:
          lib.nameValuePair "${agentsDir}/${name}.md" {
            # A store-path string, as a flake input yields, is a source too;
            # `builtins.isPath` alone would write the path as the agent's text.
            content = lib.mkDefault (lib.ai.agent.fileContent (lib.ai.agent.renderKimchi name value));
            entry = "kimchiAgents";
            ledger = agentsLedger;
            method = lib.mkDefault "copy-ro";
          })
        mergedAgents;
      }

      # .kimchi/hooks.json — devenv only, because Kimchi reads lifecycle hooks
      # from a trusted project's .kimchi/ and has no user-scope file
      # (src/extensions/kimchi-hooks/definition.ts:25-37). Kimchi never writes
      # it, so it takes the default facts and lands as a symlink. Home Manager
      # declares nothing here; its policy row warns instead. The bash-hook
      # directory is not this surface: those scripts filter the bash tool only.
      (let
        projectHooks = projectHooksFor {inherit cfg topHooks;};
      in
        lib.mkIf (isDevenv && hasHookHandlers projectHooks) {
          ai.kimchi.files.".kimchi/hooks.json" = {
            content.value.hooks = sharedHooks.render projectHooks;
            format = "json";
          };
        })

      # harness/skills/ — one entry per skill tree; Home Manager expands the
      # directory and the router expands it for devenv.
      (lib.mkIf (mergedSkills != {}) {
        ai.kimchi.files = helpers.mkSkillFiles {
          configDir = mcpAndSkillsDir;
          skills = mergedSkills;
        };
      })
    ];
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
    inherit pkgs;
    name = "kimchi";
    contextFilename = projectContextFilename;
    contextDescription = ''
      Kimchi-specific context appended after `ai.context`. Home Manager emits
      the configured filename under its harness directory, although pinned
      Kimchi discovers only `AGENTS.md` there unless the package is overridden
      compatibly. Devenv always writes project-root `AGENTS.md`.
    '';
    supportedPools = [
      "agents"
      "context"
      "environmentVariables"
      "hooks"
      "mcpServers"
      "settings"
      "skills"
    ];
    defaults.package = pkgs.ai.kimchi;
    # The builder declares these pool options and expands `agentsDir`.
    poolOptions = {
      agents.description = ''
        Kimchi agents, one `<name>.md` each: Home Manager writes
        `<configDir>/harness/agents/`, devenv a trusted project's
        `.kimchi/agents/`. A portable `{ description, instructions }` record
        renders to Kimchi frontmatter plus body; Markdown here is Kimchi's
        own and lands verbatim. Entries replace root `ai.agents` at the same
        key and null suppresses one. Root Markdown and a record's
        Claude/Copilot `tools` list have no Kimchi reading and fail
        evaluation, naming this option as the remedy. Each file is a
        read-only copy: Kimchi's /agents commands cannot edit a declared
        agent, and an agent they create beside it is left alone.
      '';
      agentsDir.description = "Directory of Kimchi-native `.md` agent files, expanded into `ai.kimchi.agents` keyed by basename minus `.md`.";
      environmentVariables.description = ''
        Environment variables exported when launching kimchi. Null suppresses
        a root entry at the same key. A variable Kimchi overwrites at launch
        (listed with its reason in packages/kimchi/extracted.json) fails
        evaluation, because a value set for it is never read.
      '';
    };
    options = {
      permissions = lib.mkOption {
        # No freeform keys: Kimchi validates the file with a `.strict()` zod
        # schema (src/extensions/permissions/config.ts:11-19), so one unknown
        # key would invalidate the whole file.
        type = lib.types.submodule {
          options = {
            allow = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = ["bash(git status)"];
              description = "Permission rules Kimchi allows without asking.";
            };
            classifierMaxTotalMs = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              description = "Total time budget for the auto-mode risk classifier, in milliseconds.";
            };
            classifierTimeoutMs = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              description = "Per-call timeout for the auto-mode risk classifier, in milliseconds.";
            };
            defaultMode = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["auto" "default" "plan" "yolo"]);
              default = null;
              description = "Permission mode a session starts in.";
            };
            deny = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = "Permission rules Kimchi refuses.";
            };
          };
        };
        default = {};
        description = ''
          Kimchi's permissions file, mirroring its schema key for key, as a
          read-only copy. Home Manager always owns
          `~/.config/kimchi/harness/permissions.json`, which Kimchi hard-codes
          and which therefore ignores `configDir`; devenv writes
          `.kimchi/permissions.json`, read in a trusted project from the
          exact devenv root, only when something is declared. `/permissions …
          save` cannot write either copy. `allow` and `deny` concatenate
          across user and project files. The
          scalars do NOT inherit per key: Kimchi fills `defaultMode` and
          `classifierTimeoutMs` with its own defaults for any project file
          that exists, and the project value wins
          (src/extensions/permissions/config.ts:56-60,98-101). So any devenv
          declaration, even `allow` alone, resets a user `defaultMode` and
          classifier timeout inside that project; declare them here too to
          keep them. `classifierMaxTotalMs` alone falls through to the user
          file. Removing the last declared key removes the project file, so
          no `{}` keeps overriding the user after the declaration is gone.
        '';
      };

      projectTrust = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = {};
        example = {
          "/home/me/src" = true;
          "/home/me/src/untrusted-fork" = false;
        };
        description = ''
          Project trust decisions keyed by absolute directory, mirroring
          Kimchi's `trust.json`. Kimchi uses the nearest decision at or above
          the working directory, so one entry covers every project below it
          and `false` denies a subtree. This is how an ACP session, which
          ignores `--approve`, trusts a project without the global
          `native.harnessSettings.defaultProjectTrust = "always"`. Home Manager
          reconciles `<configDir>/harness/trust.json` by leaf, resolving each
          key through symlinks when the writer runs because Kimchi matches the
          realpath: a declared key is Nix-owned, and a decision answered at
          Kimchi's trust prompt is unowned and survives. Devenv rejects this
          option: trust is user scope.
        '';
      };

      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/kimchi";
        description = ''
          Home Manager output directory relative to HOME. The pinned Kimchi
          discovers only the default location; a non-default value requires a
          compatible package override. Devenv uses fixed project paths.
        '';
      };

      hooks = lib.mkOption {
        type = sharedHooks.mkHooksType hookEvents;
        default = {};
        apply = lib.filterAttrs (_event: blocks: blocks != []);
        description = ''
          Kimchi lifecycle hooks appended after the shared `ai.hooks` matcher
          groups, over Kimchi's own event set. Devenv writes both into
          `.kimchi/hooks.json`, which Kimchi reads only in a trusted project
          and from the exact devenv root. Home Manager delivers nothing and
          warns about this option: Kimchi has no user-scope lifecycle hook
          file Home Manager can own. `ai.hooks`' PermissionRequest is not a
          Kimchi event, so it is left out silently. If Kimchi's opt-in Claude
          Code hook adapter is enabled, a shared hook that also reaches
          `.claude/settings.json` fires twice.
        '';
      };

      # Cast AI key — a runtime credential (file | helper), exported as
      # KIMCHI_API_KEY at launch. Reuses the repo's shared MCP credential
      # pattern (lib/mcp.nix) so the secret is read from its decrypted file
      # at runtime and never lands in the /nix/store. Set exactly one of
      # apiKey.file (sops-nix/agenix path) or apiKey.helper.
      apiKey = mcpLib.mkCredentialsOption (sidecar.environmentName "KIMCHI_API_KEY");

      gitTokens = lib.mkOption {
        type = lib.types.attrsOf (mcpLib.mkCredentialsOption "the config.json `gitTokens.<host>` leaf").type;
        default = {};
        example = {"github.com".file = "/run/secrets/kimchi-github-token";};
        description = ''
          Git tokens Kimchi's teleport and remote runs use, keyed by host.
          Kimchi reads them only from the user config.json and has no
          environment input for them, so Home Manager reads each one from its
          file or helper at activation and writes it into that owner-only
          file; the store holds only the path. Devenv rejects this option:
          without Home Manager the file is Kimchi's own.
        '';
      };

      noUpdateCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable background self-update probe via KIMCHI_NO_UPDATE_CHECK.";
      };
    };

    hm.options.native = nativeOptions "hm";
    devenv.options.native = nativeOptions "devenv";

    config = kimchiDelivery;
    installPackage = kimchiInstallPackage;
    # Context only, at a fixed key: context.filename names the Home Manager
    # harness file.
    sharedAgentsMd = _: {key = projectContextFilename;};
    # Context only: Kimchi has no rules pool.
    contentTargets = {
      backend,
      cfg,
      ...
    }: {
      context =
        if backend == "devenv"
        then projectContextFilename
        else userContextPath cfg;
    };
  }

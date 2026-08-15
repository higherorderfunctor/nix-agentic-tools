# Declares cross-app options (ai.context, ai.mcpServers,
# ai.rules, ai.settings, ai.skills, ai.agents, ai.hooks).
#
# Imported by every mkAiApp module so per-app layers
# (ai.<name>.mcpServers, etc.) compose with these top-level pools. Scalar
# defaults allow per-app overrides, lists concatenate, and named attrset pools
# reject shared/per-app duplicate keys through mergeWithCollisionCheck.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  agent = import ./agent.nix {inherit lib;};
  dirHelpers = import ./dir-helpers.nix {inherit lib;};
  hooks = import ./hooks.nix {inherit lib;};
  harnessNames = import ./runtimes.nix;
  anyHarnessEnabled = lib.any (name: lib.attrByPath ["ai" name "enable"] false config) harnessNames;
  hasHomeManagerGit = lib.hasAttrByPath ["programs" "git" "settings"] options;

  # OpenSSH rejects Home Manager's otherwise-safe ~/.ssh/config symlink inside
  # Linux user-namespace sandboxes: the root-owned Nix-store target is exposed
  # as nobody. An explicit -F accepts that same immutable target. Keep the
  # exception exact so ordinary user-owned configs retain OpenSSH's normal
  # ownership checks.
  sandboxSafeSsh = pkgs.writeShellApplication {
    name = "ai-sandbox-safe-ssh";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      if [ -n "''${HOME:-}" ]; then
        ssh_config="$HOME/.ssh/config"
        resolved_config="$(${pkgs.coreutils}/bin/readlink -f "$ssh_config" 2>/dev/null || :)"
        case "$resolved_config" in
          /nix/store/*)
            exec ${lib.getExe pkgs.openssh} -o BatchMode=yes -F "$ssh_config" "$@"
            ;;
          *) ;;
        esac
      fi

      exec ${lib.getExe pkgs.openssh} -o BatchMode=yes "$@"
    '';
  };
  sandboxSafeSshCommand = lib.getExe sandboxSafeSsh;
in {
  imports = [./app/sharedAgentsMd.nix];

  options.ai = {
    context = lib.mkOption {
      # An empty record is the unset value. Wrapping the checked submodule in
      # `nullOr` would bypass its outer XOR check during nested merging.
      type = aiCommon.optionalContentModule;
      default = {};
      apply = aiCommon.validateOptionalContent;
      description = ''
        Cross-app context fanned out to Claude, Codex, Kiro, Kimchi, and the
        Copilot devenv backend; Copilot Home Manager intentionally degrades.
        Set exactly one of `text` or `source`. Runtime-specific context appends
        after this root content in the runtime's single always-on file; its
        `filename` controls that native artifact.
      '';
      example = lib.literalExpression ''{ source = ./ai-context.md; }'';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [(import ./mcpServer/commonSchema.nix)];
      });
      default = {};
      description = ''
        MCP servers fanned out to every enabled AI app: Claude, Codex,
        Copilot, and Kiro. Per-app entries (ai.<name>.mcpServers) add
        runtime-specific servers; duplicate names across the shared and
        per-app pools fail the factory's collision check.
      '';
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf aiCommon.ruleModule;
      default = {};
      apply = aiCommon.validateRules;
      description = ''
        Cross-app modular rule files fanned out to every capable enabled AI app.
        Each attribute becomes one file in the ecosystem's native rules
        directory (Claude: `.claude/rules/<name>.md`, Kiro:
        `.kiro/steering/<name>.md`, Copilot devenv:
        `instructions/<name>.instructions.md` under `ai.copilot.projectDir`;
        Copilot Home Manager deliberately emits no normalized rules because
        github.com's reviewer consumes only the committed project tree). Codex
        instead appends rules in key order
        to its single AGENTS.md, translating `matcher` to a prose scope note.
        Kimchi has no rules pool, so root rules silently degrade for it.
        Per-app entries merge with the root pool; duplicate keys across those
        levels are a failure. Set exactly one of `text` or `source` for each
        rule. Kiro's native `inclusion` override exists only on
        `ai.kiro.rules`.
      '';
      example = lib.literalExpression ''
        {
          code-style = { text = "Use consistent formatting."; };
          testing = {
            source = ./rules/testing.md;
            matcher = [ "**/*.test.*" ];
            description = "Testing conventions";
          };
        }
      '';
    };

    rulesDir = lib.mkOption {
      type = lib.types.nullOr aiCommon.dirOptionType;
      default = null;
      description = ''
        Directory of `.md` rule files fanned out to Claude, Codex, Copilot,
        and Kiro. Each file becomes one entry in `ai.rules` keyed by the
        basename minus `.md`. Collisions with explicit `ai.rules.<name>`
        entries (or with `ai.<cli>.rules`) fail via the shared collision check.
        Accepts either a Nix path literal or `{ path, filter? }` where
        `filter : name → bool` (default: keep `.md` files). The source
        directory is NOT taken over wholesale — other derivations can
        still contribute to the same ecosystem rules dir via
        `home.file.*` / `files.*` without conflict.
      '';
      example = lib.literalExpression ''
        ./rules                                  # keep defaults
        # or
        {
          path = ./rules;
          filter = name: !(lib.hasSuffix ".bk" name);
        }
      '';
    };

    settings = lib.mkOption {
      type = aiCommon.normalizedSettingsType;
      default = {};
      description = ''
        Typed settings whose values preserve the same meaning across multiple
        AI runtimes. Each `ai.<runtime>.settings` field narrows this root
        default when non-null. The current `reasoningEffort` field lowers to
        Claude `effortLevel` and Codex `model_reasoning_effort`; the enum is
        their exact persisted semantic intersection. Set a runtime's native
        key, including an explicit null, under
        `ai.<runtime>.nativeSettings` to arbitrate against the derived default.
        Runtime-specific identifiers and lossy translations are deliberately
        excluded.
      '';
    };

    lspServers = lib.mkOption {
      type = lib.types.attrsOf aiCommon.lspServerModule;
      default = {};
      description = ''
        Typed LSP server declarations fanned out to enabled Claude, Copilot,
        and Kiro. Each per-ecosystem translator renders the native JSON shape
        on emission (Kiro: command/args; Copilot: + fileExtensions; Claude: +
        extensionToLanguage). Codex is intentionally excluded because its
        public configuration has no native LSP-server surface. Per-app entries
        (ai.<name>.lspServers) add runtime-specific servers; duplicate names
        across the shared and per-app pools fail the collision check.
      '';
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf agent.agentType;
      default = {};
      description = ''
        Agent definitions fanned out to Claude and Copilot. Portable semantic
        records (`{ description, instructions, tools?, codex? }`) also fan out
        to Codex; `tools` is rendered only for Claude and Copilot because Codex
        has no equivalent agent field. Legacy Markdown/path values remain
        Claude/Copilot-only and cause a clear assertion when Codex is enabled.
        Each entry becomes a file:
        - Claude  → ~/.claude/agents/<name>.md
        - Copilot → .github/agents/<name>.agent.md (devenv) or
                    ~/.copilot/agents/<name>.md (HM)
        - Codex   → ~/.codex/agents/<name>.toml (HM) or
                    .codex/agents/<name>.toml (devenv)
        Kiro intentionally excluded, but no longer because its agents are
        untyped JSON — `ai.kiro.agents` is a typed record now. The blocker is
        the tool vocabulary: this pool's `tools` list uses Claude/Copilot tool
        NAMES (`Bash`, `Read`), while Kiro takes capability TAGS (`shell`,
        `read`, `@mcp`), so lowering one to the other needs a translation
        table rather than a pass-through. Use `ai.kiro.agents` directly for
        that ecosystem. Per-app overrides (ai.<cli>.agents) merge on top;
        collisions fail.
      '';
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr aiCommon.dirOptionType;
      default = null;
      description = ''
        Directory of legacy `.md` agent files fanned out to Claude and
        Copilot. Each file becomes one entry in `ai.agents` keyed by the
        basename minus `.md`. Codex is excluded because it requires semantic
        records rendered as standalone TOML; use explicit `ai.agents` records
        for three-runtime fanout. Kiro is excluded because these are Markdown
        files while Kiro's agents are JSON, and because its tool tags are a
        different vocabulary from the Claude/Copilot tool names this pool
        carries; use `ai.kiro.agentsDir` for that ecosystem.
      '';
      example = lib.literalExpression ''./agents'';
    };

    hooks = lib.mkOption {
      type = hooks.hooksType;
      default = {};
      apply = lib.filterAttrs (_event: blocks: blocks != []);
      description = ''
        Portable command hooks fanned out to Claude and Codex. The event set is
        their exact lifecycle intersection: ${lib.concatStringsSep ", " hooks.portableEvents}.
        Matcher strings pass through unchanged, so use regex syntax supported
        by both runtimes. Per-runtime hook maps append after these shared
        matcher groups. Kiro is excluded because its v3 trigger schema is not
        semantically interchangeable.
      '';
    };

    gitSshConfigWorkaround = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install a sandbox-safe Git SSH default whenever any supported AI
        harness is enabled. The wrapper behaves like ordinary OpenSSH unless
        `~/.ssh/config` resolves into the immutable Nix store; only then does
        it pass that same file through explicit `-F`, avoiding user-namespace
        owner remapping without discarding host/key routing. OpenSSH batch mode
        makes missing credentials fail instead of opening a password dialog.

        Home Manager contributes `programs.git.settings.core.sshCommand` at
        `mkDefault` priority. Devenv contributes `GIT_SSH_COMMAND` to the shell
        environment at `mkDefault` priority so its Git and every harness it
        launches receive the same behavior. Set this false to manage Git SSH
        delivery independently.
      '';
    };

    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Environment variables fanned out to every enabled AI app with a
        launcher wrapper: Codex, Copilot, Kimchi and Kiro. Per-app entries
        (ai.<name>.environmentVariables) add runtime-specific variables;
        duplicate names across the shared and per-app pools fail the collision
        check.

        Delivered by baking them into each app's wrapper, so they scope to
        that process and the commands it spawns. They are NOT written into
        the Home Manager session or the devenv project shell — this module
        does not touch the shell environment, because a variable exported
        there also reaches the developer's own session and every other
        process in it. Codex's `shell_environment_policy` is a different
        thing again: it filters what SPAWNED commands inherit, not what
        Codex itself runs with.

        Claude does NOT consume this pool — it has no wrapper here, and
        `ai.claude.nativeSettings.env` is its native equivalent (upstream writes
        it into `~/.claude/settings.json`).
      '';
    };

    # Internal module-to-module channel. NOT a consumer surface: it exists so
    # `gitSshConfigWorkaround` can reach each harness's launcher wrapper
    # without writing into `ai.<cli>.environmentVariables`, which is
    # collision-checked and would reject the consumer's own entry for the same
    # key. Read by the per-package factories; `internal` keeps it out of the
    # generated options documentation.
    _sandboxSafeSshCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      internal = true;
      visible = false;
      description = "Resolved sandbox-safe Git SSH command, delivered to harness wrappers. Set by `gitSshConfigWorkaround`; not for direct use.";
    };

    shell = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.bash";
      description = ''
        Shell each enabled AI app uses to execute the commands it runs.
        `null` (the default) does not touch the shell, so every existing
        consumer keeps current behavior and opting in is explicit.
        Override per app with `ai.<name>.shell`; a non-null per-app value
        wins, `null` inherits this one.

        Fans out to **Claude, Codex and Kiro only**. Claude reads
        `CLAUDE_CODE_SHELL` from its settings file; Codex and Kiro read
        `SHELL` from their own process environment and receive it baked into
        their launcher wrapper, on both backends. An explicit
        `ai.<name>.environmentVariables.SHELL` beats this option, the same way
        an explicit `settings.env` entry beats it for Claude. Copilot and
        Kimchi are
        deliberately excluded rather than silently ignored: neither one's
        shell selection has been established, so `ai.copilot.shell` and
        `ai.kimchi.shell` do not exist and setting either is an eval error.

        Takes a **package, not a path**, and that is load-bearing. Every
        runtime here falls back when the configured shell is unusable, and
        two of them do it without a usable diagnostic: Claude silently
        resolves its own bash (measured — it ignores even an explicit
        `SHELL`), and Codex falls back to the *password-database* shell,
        which is exactly the shell an operator is likely trying to move off.
        A package is guaranteed to exist in the store at activation and is
        GC-rooted by the generation that references it, so that entire class
        of silent no-op is eliminated by construction instead of by a runtime
        check none of these runtimes performs.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Cross-app skills fanned out to every enabled AI app: Claude, Codex, Copilot, and Kiro.";
    };

    skillsDir = lib.mkOption {
      type = lib.types.nullOr aiCommon.dirOptionType;
      default = null;
      description = ''
        Directory-of-directories fanned out to Claude, Codex, Copilot, and
        Kiro; each immediate subdirectory becomes one entry in `ai.skills`
        keyed by the subdir name. Collisions with explicit
        `ai.skills.<name>` entries (or with `ai.<cli>.skills`) fail via the
        shared collision check. The default filter accepts every subdirectory;
        supply a
        `{ path, filter? }` submodule with `filter : name → bool` to
        exclude specific subdirs.
      '';
      example = lib.literalExpression ''
        ./skills
        # or
        { path = ./skills; filter = name: name != "draft"; }
      '';
    };
  };

  # L1 → L2 fanout: expand Dir options into per-file entries on
  # the matching L2 pools. mkDefault priority lets explicit
  # `ai.<pool>.<name>` contributions override (this is the L1→L2
  # fanout specifically, not a collision; collisions are handled
  # at the L2↔L3 boundary by the factory's mergeWithCollisionCheck
  # helper).
  #
  # Emission logic lives at L4 inside each per-CLI factory. This
  # layer only reshapes the L1 Dir option into L2 per-file entries.
  config = lib.mkMerge [
    {
      # THE one sanctioned root-pool write in this repo. Every other module
      # writes `ai.<runtime>.<pool>`, enforced by the provenance guard in
      # `checks/module-eval.nix` (`rootPoolViolations`), which allowlists this
      # FILE — see `rootPoolAllowedFiles` there.
      #
      # It is legitimate because the DESTINATION is the root pool by
      # definition: `ai.rulesDir` is itself a ROOT option, so expanding it onto
      # any per-runtime pool would silently relocate a consumer's own
      # declaration to a level they never wrote. This module declares those
      # options, so it is the one place with nowhere else to expand to.
      ai = {
        rules = lib.mkIf (config.ai.rulesDir != null) (
          lib.mapAttrs (_: lib.mkDefault) (dirHelpers.rulesFromDir config.ai.rulesDir)
        );
        skills = lib.mkIf (config.ai.skillsDir != null) (
          lib.mapAttrs (_: lib.mkDefault) (dirHelpers.skillsFromDir config.ai.skillsDir)
        );
        agents = lib.mkIf (config.ai.agentsDir != null) (
          lib.mapAttrs (_: lib.mkDefault) (dirHelpers.agentsFromDir config.ai.agentsDir)
        );
      };
    }
    # Home Manager has a native Git surface, so say it in Git's own config.
    #
    # Everywhere else this rides each enabled harness's LAUNCHER WRAPPER, one
    # `GIT_SSH_COMMAND` per harness, rather than the single devenv `env` write
    # this used to be. That write was one line and reached every harness at
    # once, but it did so by exporting into the PROJECT SHELL — so it also
    # rewrote Git's SSH command for the developer's own session and for every
    # other process in the project. A wrapper is inherited across fork/exec,
    # so Git spawned BY a harness still sees it; nothing else does.
    #
    (lib.mkIf (config.ai.gitSshConfigWorkaround && anyHarnessEnabled) (
      if hasHomeManagerGit
      then {
        programs.git.settings.core.sshCommand = lib.mkDefault sandboxSafeSshCommand;
      }
      else {
        # Published on the INTERNAL channel, never into
        # `ai.<cli>.environmentVariables`.
        #
        # Writing a module default into that pool looks equivalent and is not:
        # `mergeWithCollisionCheck` decides collisions with
        # `builtins.intersectAttrs`, which sees KEY PRESENCE and knows nothing
        # about `mkDefault`. So a module contribution there turns any consumer
        # who also sets `ai.environmentVariables.GIT_SSH_COMMAND` into a hard
        # eval failure — naming a per-CLI pool they never wrote, and firing
        # even for harnesses that are merely imported, since
        # `collisionAssertions` is emitted outside `mkIf cfg.enable`.
        #
        # The pool belongs to the consumer. Module contributions ride this
        # channel and are merged UNDER the pool at each wrapper call site, so
        # an explicit entry simply wins.
        ai._sandboxSafeSshCommand = sandboxSafeSshCommand;
      }
    ))
  ];
}

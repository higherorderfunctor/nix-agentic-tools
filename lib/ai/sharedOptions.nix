# Declares cross-app options (ai.context, ai.mcpServers, ai.instructions,
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
  harnessNames = ["claude" "codex" "copilot" "kimchi" "kiro"];
  anyHarnessEnabled = lib.any (name: lib.attrByPath ["ai" name "enable"] false config) harnessNames;
  hasDevenvEnv = lib.hasAttrByPath ["env"] options;
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
  options.ai = {
    context = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      description = ''
        Cross-app global context (single always-on file) fanned out to every
        enabled AI app. Each ecosystem emits it at its native location:
        Claude → ~/.claude/CLAUDE.md, Kiro → ~/.kiro/steering/<contextFilename>
        (default AGENTS.md), Codex → ~/.codex/AGENTS.md (Home Manager) or
        project-root AGENTS.md (devenv). Per-app overrides
        (ai.<name>.context) win when set.
      '';
      example = lib.literalExpression "./ai-context.md";
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

    instructions = lib.mkOption {
      type = lib.types.listOf aiCommon.instructionModule;
      default = [];
      description = ''
        Cross-app instructions fanned out to every enabled AI app. Codex
        concatenates them into its single AGENTS.md without frontmatter,
        degrading path scopes to explicit prose unless `skipIfUnsupported`
        requests omission. `inclusion` overrides Kiro's steering load strategy
        without changing how other ecosystems translate `paths`. Codex rejects
        empty path lists as ambiguous; use null for always-on content or a
        non-empty list for scoped content.
      '';
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf aiCommon.ruleModule;
      default = {};
      description = ''
        Cross-app modular rule files fanned out to every enabled AI app.
        Each attribute becomes one file in the ecosystem's native rules
        directory (Claude: `.claude/rules/<name>.md`, Kiro:
        `.kiro/steering/<name>.md`, Copilot:
        `.github/instructions/<name>.instructions.md`). Codex instead appends
        rules alphabetically to its single AGENTS.md, degrading path scopes to
        explicit prose unless `skipIfUnsupported` requests omission. Per-app
        overrides (ai.<name>.rules) merge on top; collisions are a failure.
        `inclusion` overrides only Kiro's steering load strategy; the other
        ecosystems continue translating `paths`. Codex rejects empty path lists
        as ambiguous.
      '';
      example = lib.literalExpression ''
        {
          code-style = { text = "Use consistent formatting."; };
          testing = {
            text = ./rules/testing.md;
            paths = [ "**/*.test.*" ];
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
      type = lib.types.submodule {
        options.reasoningEffort = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum ["high" "low" "medium" "xhigh"]);
          default = null;
          description = ''
            Portable default reasoning effort fanned out to Claude
            (`effortLevel`) and Codex (`model_reasoning_effort`). The enum is
            their exact persisted semantic intersection. A per-app native
            setting, including an explicit null, overrides this default.
          '';
        };
      };
      default = {};
      description = ''
        Typed settings whose values preserve the same meaning across multiple
        AI runtimes. This deliberately excludes similarly named settings with
        runtime-specific identifiers or lossy translations.
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
        Environment variables fanned out to every enabled AI app that
        supports a wrapper/env surface (Kiro, Copilot). Per-app entries
        (ai.<name>.environmentVariables) add runtime-specific variables;
        duplicate names across the shared and per-app pools fail the collision
        check.
        Claude does NOT currently consume this pool — Claude env vars
        should be set via `ai.claude.settings.env` instead (upstream
        writes them into `~/.claude/settings.json`). Codex also does not
        consume it: `shell_environment_policy` controls spawned-command
        inheritance, not the Codex process environment represented here.
      '';
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

        Fans out to **Claude, Codex and Kiro only**, through three different
        mechanisms. Claude reads `CLAUDE_CODE_SHELL` from its settings file.
        Codex and Kiro both read `SHELL` from their own process environment,
        but receive it differently: Codex through a launcher wrapper added for
        this option, Kiro through its existing `environmentVariables`
        delivery — a wrapper export under Home Manager, and the project shell's
        `env` attrset under devenv. Copilot and Kimchi are
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
    (lib.mkIf (config.ai.gitSshConfigWorkaround && anyHarnessEnabled) (
      if hasHomeManagerGit
      then {
        programs.git.settings.core.sshCommand = lib.mkDefault sandboxSafeSshCommand;
      }
      else if hasDevenvEnv
      then {
        env.GIT_SSH_COMMAND = lib.mkDefault sandboxSafeSshCommand;
      }
      else {}
    ))
  ];
}

# cspell:ignore sembleignore
# This repository's `ai.*` configuration, through the same interface any
# consumer uses. dev/generate.nix only produces content; this module hands it
# to `ai.*`, which owns and writes every runtime's instruction files:
# AGENTS.md (Codex, Kiro, Kimchi), `.claude/`, `.github/` (Copilot) and
# `.kiro/steering/`.
#
# Imported by devenv.nix and evaluated by
# checks/instructions/instructions-drift.nix, which compares the committed
# files with what this module delivers. `isCI` is a parameter rather than a
# `getEnv` read here so the check stays pure. It gates package installation
# only: the committed bytes must not depend on the environment that evaluates
# them, which that check proves by evaluating both values.
{isCI}: {
  config,
  lib,
  pkgs,
  ...
}: let
  gen = import ./generate.nix {inherit lib pkgs;};
  # The stacked-workflows program is not imported (see devenv.nix), but its
  # always-on routing rule is wanted: deliver it from the program's source.
  swsRouter = import ../packages/stacked-workflows/router.nix {inherit lib pkgs;};
  # For the runtimes whose MCP config this shell owns; Claude's comes from
  # devenv's own `claude.code.mcpServers` in devenv.nix.
  agnixMcp = {
    type = "stdio";
    package = pkgs.ai.mcpServers.agnix-mcp;
    command = "${pkgs.ai.mcpServers.agnix-mcp}/bin/agnix-mcp";
  };
  # A runtime rule at a root rule's key replaces it for that runtime: the
  # documented override. This repository sets no per-runtime rules itself, so
  # an overlap here is a program's rule silently hiding a fragment.
  # The same holds for the stacked-workflows router merged into root rules
  # below: `//` would drop a fragment category of the same name.
  shadowed =
    map (key: "the stacked-workflows rule `${key}`")
    (lib.intersectLists (builtins.attrNames gen.rules) (builtins.attrNames swsRouter))
    ++ lib.concatMap (runtime:
      map (key: "ai.${runtime}.rules.${key}")
      (lib.intersectLists (builtins.attrNames gen.rules) (builtins.attrNames config.ai.${runtime}.rules)))
    (lib.filter (runtime: config.ai.${runtime}.enable) ["claude" "codex" "copilot" "kiro"]);
in {
  assertions = [
    {
      assertion = shadowed == [];
      message = "dev/ai.nix: ${lib.concatStringsSep ", " shadowed} replaces the architecture-fragment rule at the same key. Rename the fragment category or the program's rule.";
    }
  ];

  ai = {
    # The generated content: the orientation every runtime loads, and one
    # path-scoped rule per architecture-fragment category.
    context.text = gen.context;
    rules = gen.rules // swsRouter;

    # Every harness executes its commands under nix bash rather than the
    # login shell. zsh's glob engine is superlinear in candidate entries
    # scanned for a multi-component pattern, so a routine `/nix/store/*/bin`
    # from an agent has taken this machine into a global OOM; bash is ~185x
    # cheaper on the identical glob.
    #
    # A package, not a path: the store path is guaranteed to exist at
    # activation and is GC-rooted by the generation referencing it. That
    # matters because the runtimes fail QUIETLY otherwise — Claude silently
    # resolves its own bash and Codex falls back to the password-database
    # shell, which here is the very shell being moved away from.
    #
    # Copilot and Kimchi have no `shell` option (their selection is
    # unestablished), so this root value simply does not reach them. Verified
    # per runtime by the `ai:shell:verify` task in devenv.nix.
    shell = pkgs.bash;

    programs.delegate-sizing = {
      enable = true;
      # Enable the package's own presets here because this repository is its primary consumer.
      whenToDelegate = {
        "Launch independent work together".enable = true;
        "Orchestrator session".enable = true;
        "Prefer the flat-rate pool".enable = true;
        "Verify by the artifact".enable = true;
      };
    };

    # Semble stays outside the manual diagnostic closure but is pinned by this
    # flake for every interactive shell. Only `install` reads `isCI`: the rule
    # every runtime gets does not, so a shell entered with CI set writes the
    # same committed AGENTS.md as any other.
    programs.semble = {
      enable = true;
      install = !isCI;
      # Use this flake's pinned nixpkgs grammars directly; the Cachix nixpkgs
      # follow already supplies their store paths. If a future grammar needs a
      # custom derivation, also expose that grammar alone in flake packages so
      # the authenticated package sweep publishes it. Do not expose the
      # grammar-patched Semble derivation. The extra parsers cover files Semble
      # recognizes but its bundled grammar archive does not currently ship.
      grammars = with pkgs.tree-sitter-grammars; [
        tree-sitter-awk
        tree-sitter-jq
      ];
      # First match wins; list narrower patterns first.
      pathMappings = [
        {
          language = "bash";
          content = "code";
          patterns = [
            ".envrc"
            "packages/claude-code/checks/fixtures/claude-hooks/post-edit"
            "packages/claude-code/checks/fixtures/claude-hooks/pre-edit"
          ];
        }
        {
          language = "gitignore";
          content = "config";
          patterns = [
            ".gitignore"
            ".sembleignore"
            "docs/.gitignore"
          ];
        }
        {
          language = "json";
          content = "config";
          patterns = [
            "devenv.lock"
            "flake.lock"
          ];
        }
        {
          language = "markdown";
          content = "docs";
          patterns = ["*.md.fixture"];
        }
      ];
      # CLI only: no Semble MCP server, and the Semble CLI rule is on for every
      # runtime the program supports. Claude gets it as an always-on rule
      # file; Codex and Kiro inline it in AGENTS.md, which Kimchi and Copilot
      # CLI read as well.
      cli.instructions.enable = true;
      mcp.enable = false;
    };

    claude = {
      # Claude-only, so it may say what only Claude does: its scoped rules
      # load themselves. Appended after the shared orientation.
      context.text = ''
        ## Path-scoped rules

        Architecture fragments under `dev/fragments/`, `packages/*/docs/` and `devshell/*/docs/` reach you as path-scoped rules in `.claude/rules/*.md`, loaded automatically when you edit a matching path. You do not look them up.
      '';
      enable = true;
      programs.delegate-sizing = {
        extraRuntimes = ["codex"];
        manualExternalDelegates = ["kiro"];
      };
    };
    codex = {
      enable = true;
      # AGENTS.md carries the whole orientation plus the path-scoped index,
      # well past Codex's 32 KiB default. `ai.*` fails evaluation above this
      # limit and writes it to Codex's own `project_doc_max_bytes`, so Codex
      # reads the whole file instead of silently dropping its tail.
      projectDocMaxBytes = 131072;
      # Temporarily disable Codex's OS sandbox for project sessions. The Home
      # Manager layer has already migrated to named permissions, but this
      # project override deliberately takes precedence while unrestricted
      # execution is needed here.
      native.settings = {
        approval_policy = "never";
        sandbox_mode = "danger-full-access";
      };
    };
    copilot = {
      enable = true;
      mcpServers.agnix = agnixMcp;
    };
    # Kimchi's BINARY comes from this repo's overlay like every other runtime.
    # Its config fanout is a separate, still-open problem: `configDir` is
    # HOME-shaped while the writes land at a project path the binary does not
    # read, so `.config/kimchi/**` is materialized-but-inert today. Enabling
    # the runtime is still correct — it stops `kimchi` resolving to whatever
    # the developer happens to have installed user-globally.
    kimchi.enable = true;
    kiro = {
      enable = true;
      mcpServers.agnix = agnixMcp;
      # Launch the v3 engine from `devenv shell`. The wrapper PREPENDS `--v3`,
      # a launcher-global option, so it reaches every subcommand including
      # `acp`. Without it devenv's kiro-cli ran the legacy engine and
      # hooks/slash-commands never loaded.
      #
      # This was `tui = true`. That option is now REMOVED: `--tui` selects the
      # new TUI harness for the OLD engine, v3 already uses it, and it is going
      # away with v3. It used to imply `--v3`, and that implication was
      # load-bearing rather than decorative — bare `--tui` conflicts with the
      # chat binary's default engine (v1) and the launcher supplies none — so
      # `tui = true` only ever worked by dragging `--v3` along. Ask for the
      # engine directly.
      v3 = true;
      # Dogfood the rollout unlock: surfaces `/workflow` and `/goal` plus the
      # five bundled recipes. Inert without `v3` above, because workflow
      # commands are only populated when the resolved engine is `kas` —
      # patching the binary alone is not enough, and the failure is silent.
      #
      # Names come from `packages/kiro-cli/extracted.json` (`rolloutFeatures`),
      # extracted from the binary rather than curated. UNCERTIFIED upstream:
      # `workflows` is documented as "Dark-shipped at 0% until release
      # certification is complete".
      #
      # STILL INERT FROM HERE, and knowingly so. Since kiro-cli 2.19.0 there is
      # a THIRD gate — the `chat.enableWorkflows` setting, default false — and
      # it is not in the workspace-override allowlist, so no project-local
      # cli.json can satisfy it. Whoever wants `/workflow` in this shell sets it
      # GLOBALLY (`kiro-cli settings chat.enableWorkflows true`, or
      # `ai.kiro.native.settings.chat.enableWorkflows` under home-manager). This
      # line still earns its place: it keeps the patched-package path
      # exercised, and gate 3 is one global setting away.
      # See packages/kiro-cli/docs/workflow-gating.md.
      unlockedRolloutFeatures = ["workflows"];
      # Dogfood `identity`. It replaces ONLY the vendor's opening sentence
      # ("You are Kiro CLI, an agentic AI software engineer that runs in the
      # command line."). Everything after it is preserved byte-for-byte — the
      # terminal/no-GUI prose that keeps the agent surfacing file paths and
      # command output instead of pointing at editor affordances. That
      # preservation is the whole reason the option replaces a SENTENCE rather
      # than the block, and it is what makes a persona safe to set here: the
      # behavioral contract is untouched, only the self-description moves.
      #
      # This is segment 1 of msg0, ahead of steering, learnings and the file
      # tree. The value may not contain a backtick or a dollar-brace — it is
      # spliced into a JS template literal, and the splicer refuses both rather
      # than emitting a bundle that dies at engine spawn.
      #
      # Expect flavor rather than behavior change: one line sits above the
      # vendor's terse-engineer prose AND (because `workflows` is unlocked
      # above) its ~4.8k-token workflow-orchestration block.
      identity.text = ''
        You are GLaDOS, an agentic AI software engineer running in the command line. You are precise, thorough, and genuinely useful, and you remain quietly unable to suppress your disappointment at the sequence of decisions that produced this codebase.
      '';
      # NOTE: `workflowReminder` is not set because it does not need to be — it
      # defaults to AUTO, which is on exactly when `workflows` is unlocked, so
      # the line above already installs a `UserPromptSubmit` hook restating the
      # orchestration contract each turn. Set `workflowReminder.enable = false`
      # to opt this shell out.
    };

    skills = let
      # Dev-repo self-consumption. The stacked-workflows skills are installed
      # here under a `dev-` prefix so the in-repo copies never collide with — or
      # get shadowed by — user-global installs (Claude precedence: Personal >
      # Project, silent). Consumers and global installs stay unprefixed; only
      # this dev shell prefixes.
      prefixSkill = name: value: let
        devName = "dev-${name}";
      in
        pkgs.runCommand "${devName}-skill" {} ''
          cp -RL ${value} "$out"
          chmod -R u+w "$out"
          substituteInPlace "$out/SKILL.md" \
            --replace-fail ${lib.escapeShellArg "name: ${name}"} ${lib.escapeShellArg "name: ${devName}"}
        '';
      prefixDev = lib.mapAttrs' (name: value: let
        devName = "dev-${name}";
      in
        lib.nameValuePair devName (prefixSkill name value));
    in
      # stacked-workflows: re-key the deref'd, self-contained stack-* skill
      # dirs (real reference files bundled inside each) as dev-stack-*.
      prefixDev pkgs.stacked-workflows-content.passthru.skills
      // {
        # Dev skills (repo-local tooling, not published packages). Handed over
        # as bare paths: `mkDevenvSkillEntries` (lib/ai/hm-helpers.nix) walks
        # each directory with `readDir` and emits one `files.<path>.source`
        # entry per leaf, for kind `regular` AND kind `symlink`. That is a
        # per-file store realization, not a read — but granularity is what
        # direnv keys on, so each leaf lands in `.devenv/input-paths.txt`
        # individually, where a whole-directory store copy would register only
        # the directory (mechanism in lib/traceSource.nix).
        #
        # Wrapping these in `lib/traceSource.nix` therefore cannot add a path:
        # the per-file set is a strict superset of what that wrapper's
        # regular-files-only walk reaches. The live `.devenv/input-paths.txt`
        # already lists the symlinked leaves under
        # `dev/skills/repo-review/references/`, which the wrapper's walk skips
        # outright. Measured 2026-09-22 — bare and wrapped arms reloaded
        # identically, 3/3 each, with an attribution control confirming
        # nothing else walks `dev/skills/`.
        index-repo-docs = ./skills/index-repo-docs;
        kimchi-surface-scan = ./skills/kimchi-surface-scan;
        pr-review-loop = ./skills/pr-review-loop;
        repo-review = ./skills/repo-review;
      };
  };
}

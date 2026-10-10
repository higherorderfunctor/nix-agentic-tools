# cspell:ignore nemotron sembleignore zhipu
# `isCI` is a parameter so instructions-drift stays pure; it gates installation
# only, keeping the committed projections independent of the evaluator environment.
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
  agnixMcp = {
    type = "stdio";
    package = pkgs.ai.mcpServers.agnix-mcp;
    command = "${pkgs.ai.mcpServers.agnix-mcp}/bin/agnix-mcp";
  };
  # A per-runtime or stacked-workflows rule at a fragment category's key would
  # silently hide that fragment, so fail on any overlap.
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
    context.text = gen.context;
    rules = gen.rules // swsRouter;

    # zsh has OOM'd this machine on `/nix/store/*/bin`; bash is ~185x cheaper.
    # A package keeps the shell available, avoiding the runtimes' silent fallbacks.
    shell = pkgs.bash;

    programs.delegate-routing = {
      enable = true;
      # The package ships no Kimchi-served families.
      families = {
        deepseek.deepseek-flash = {
          avoidFor = "review, building code, correctness judgment; knowledge-heavy questions";
          effort = "thinks by default; low for reads, high for tracing; never cap output tokens small (returns empty)";
          match = "deepseek-v*-flash*";
          tier = "small";
          useFor = "codebase exploration, research reads, compaction, trivial re-verification";
        };
        minimax.minimax = {
          avoidFor = "judging or review (abstains, weak abstract reasoning)";
          effort = "no documented knob; expect long reasoning traces";
          match = "minimax-m*";
          tier = "mid";
          useFor = "well-scoped code to a spec; screenshot or image input";
        };
        moonshot = {
          kimi-k2 = {
            avoidFor = "build subagents on a time budget (slow, times out); mixed-goal prompts";
            effort = "always thinks";
            match = "kimi-k2*";
            tier = "mid";
            useFor = "coding with image input";
          };
          kimi-k3 = {
            avoidFor = "simple or latency-bound work (slow, always thinks); ambiguous briefs; mid-session model switches";
            effort = "always thinks; treat effort as fixed";
            match = "kimi-k3*";
            tier = "strong";
            useFor = "orchestration and review; frontend and browsing-heavy agentic work";
          };
        };
        nvidia.nemotron-ultra = {
          avoidFor = "review, building code, multi-file edits, long-horizon planning";
          effort = "keep the reasoning budget low; the value is speed";
          match = "nemotron-*-ultra*";
          tier = "small";
          useFor = "cheapest, fastest long-context reads: exploration, doc ingestion, confirming tests pass";
        };
        zhipu = {
          glm = {
            avoidFor = "image input (text-only); quick lookups (thinking cannot be turned off)";
            effort = "low, high or max; high default, max for judging";
            match = "glm-[0-9]*.[0-9]";
            tier = "strong";
            useFor = "planning, spec writing, judging; hard multi-file coding";
          };
          glm-flash = {
            avoidFor = "edits near untested working code; flaky tasks (extra time does not help); hard reasoning";
            effort = "token-hungry thinking; keep the default effort";
            match = "glm-*-flash";
            tier = "mid";
            useFor = "code to a spec; the writer in a writer-judge loop with glm; image or document input";
          };
        };
      };
      routing = {
        "Local limits" = {
          always = true;
          source = ./house-rules/local-limits.md;
        };
        "Orchestrator session".enable = true;
      };
      runtimes = {
        claude = {
          extraRuntimes = ["codex"];
          manualExternalDelegates = ["kimchi" "kiro"];
          routing."Pool drain" = {
            after = ["Size the work"];
            always = true;
            source = ./house-rules/pool-drain.md;
          };
        };
        kimchi.models = [{vendors = ["deepseek" "minimax" "moonshot" "nvidia" "zhipu"];}];
        # Operator choice: GPT models cost more credits on Kiro, so select Anthropic
        # only, and not Fable, which this account does not have.
        kiro = {
          models = [{families = ["haiku" "opus" "sonnet"];}];
        };
      };
    };

    # Only installation reads isCI, so committed instructions never depend on it.
    programs.semble = {
      enable = true;
      install = !isCI;
      # Grammars Semble recognizes but its bundled archive does not ship.
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
      cli.instructions.enable = true;
      mcp.enable = false;
    };

    claude = {
      context.text = ''
        ## Path-scoped rules

        Architecture fragments under `dev/fragments/` and `packages/*/docs/` reach you as path-scoped rules in `.claude/rules/*.md`, loaded automatically when you edit a matching path. You do not look them up.
      '';
      enable = true;
      mcpServers = {
        agnix = agnixMcp;
        devenv = {
          type = "http";
          url = "https://mcp.devenv.sh/mcp";
        };
      };
    };
    codex = {
      enable = true;
      # AGENTS.md exceeds Codex's 32 KiB default; raise its read limit to keep the tail.
      projectDocMaxBytes = 131072;
    };
    copilot = {
      enable = true;
      mcpServers.agnix = agnixMcp;
    };
    kimchi = {
      enable = true;
      extensions.workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
      native.harnessSettings.resources = {
        "extensions.ferment-v2" = true;
      };
    };
    kiro = {
      mcpServers.agnix = agnixMcp;
      cli = {
        enable = true;
        tweaks = {
          # Replacing only the opening sentence preserves the vendor's behavioral prose.
          # No backticks or dollar-braces: the value goes into a JS template literal.
          identity.text = ''
            You are GLaDOS, an agentic AI software engineer running in the command line. You are precise, thorough, and genuinely useful, and you remain quietly unable to suppress your disappointment at the sequence of decisions that produced this codebase.
          '';
        };
        # Select v3 so this configuration's hooks and slash commands load.
        v3 = true;
        # Exercise the patched-package path. Devenv cannot set the global
        # chat.enableWorkflows gate; Home Manager users set
        # ai.kiro.cli.workflows.enable; see packages/kiro-cli/docs/workflow-gating.md.
        workflows.enable = true;
      };
    };

    skills = let
      # A dev- prefix prevents user-global stack-* skills from shadowing these copies.
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
      prefixDev pkgs.stacked-workflows-content.passthru.skills
      // {
        # The delivery router tracks each leaf for direnv watches; wrapping these
        # directories in lib/traceSource.nix would add nothing (measured 2026-09-22).
        delegate-evidence = ./skills/delegate-evidence;
        index-repo-docs = ./skills/index-repo-docs;
        kimchi-egress-report = ./skills/kimchi-egress-report;
        kimchi-surface-scan = ./skills/kimchi-surface-scan;
        pr-review-loop = ./skills/pr-review-loop;
        repo-review = ./skills/repo-review;
      };
  };
}

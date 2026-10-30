# cspell:ignore sembleignore
# `isCI` is a parameter so instructions-drift stays pure; it gates installation
# only, keeping the committed projections independent of the evaluator environment.
{isCI}: {
  config,
  lib,
  pkgs,
  ...
}: let
  agnixMcp = {
    type = "stdio";
    package = pkgs.ai.mcpServers.agnix-mcp;
    command = "${pkgs.ai.mcpServers.agnix-mcp}/bin/agnix-mcp";
  };
  disableRules = lib.mapAttrs (_: _: {enable = false;});
  gen = import ./generate.nix {inherit lib pkgs;};
  noSkills = lib.mapAttrs (_: _: null) config.ai.skills;
  optionPaths = import ../lib/ai/option-paths.nix {inherit lib;};
  # Keep github.com's reviewer context bounded. New categories stay local until
  # explicitly selected here; their source and local-runtime delivery stay shared.
  reviewerCategories = [
    "ai-config-scope"
    "ai-module-contract"
    "beads"
    "coding-standards"
    "commit-convention"
    "config-parity"
    "facets"
    "git"
    "kiro-agents"
    "kiro-settings"
    "mcp-secrets"
    "mcp-services"
    "microvm"
    "open-keys"
    "packaging"
    "project-overview"
  ];
  # A runtime may omit a fragment, but replacement content would silently hide
  # its source.
  shadowed = lib.concatMap (runtime: let
    path = optionPaths.pool runtime "rules";
    replacements = lib.filterAttrs (_: rule: rule.enable || rule.text != "" || rule.source != null) (lib.getAttrFromPath path config);
  in
    map (key: lib.showOption (path ++ [key]))
    (lib.intersectLists (builtins.attrNames gen.rules) (builtins.attrNames replacements)))
  (lib.filter (runtime: config.ai.${runtime}.enable) (builtins.attrNames optionPaths.records));
  # zsh has OOM'd this machine on `/nix/store/*/bin`; bash is ~185x cheaper.
  # A package keeps the shell available, avoiding the runtimes' silent fallbacks.
  shell = pkgs.bash;
in {
  assertions = [
    {
      assertion = shadowed == [];
      message = "dev/ai.nix: ${lib.concatStringsSep ", " shadowed} replaces the architecture-fragment rule at the same key. Rename the fragment category or the program's rule.";
    }
  ];

  ai = {
    inherit (gen) rules;

    programs = {
      peer-communication = {
        runtimes = {
          copilot.enable = false;
          # Kiro is a build probe only; exclude peer communication rules.
          kiro.enable = false;
        };
      };

      # Only installation reads isCI, so committed instructions never depend on it.
      semble = {
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
        # Kiro is a build probe only; exclude Semble CLI guidance.
        runtimes.kiro.cli.instructions.enable = false;
      };
    };

    claude = {
      inherit shell;
      context.text = ''
        ## Path-scoped rules

        Architecture fragments under `dev/fragments/` and `packages/*/docs/` reach you as path-scoped rules in `.claude/rules/*.md`, loaded automatically when you edit a matching path. You do not look them up.
      '';
      mcpServers = {
        agnix = agnixMcp;
        devenv = {
          type = "http";
          url = "https://mcp.devenv.sh/mcp";
        };
      };
    };
    codex = {
      inherit shell;
      # Named local guidance exceeds the default budget; activation delivers
      # this configuration together with the generated AGENTS.md.
      projectDocMaxBytes = 131072;
    };
    copilot = {
      enable = true;
      github = {
        rules = disableRules (
          lib.filterAttrs (name: _: !(lib.elem name reviewerCategories)) gen.rules
        );
        # These skills operate the local session; github.com receives none of them.
        skills = noSkills;
      };
    };
    kimchi = {
      extensions.workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
      native.harnessSettings.resources = {
        "extensions.ferment-v2" = true;
      };
    };
    # Kiro runs only to probe main's build: it reads the shared AGENTS.md, and
    # its own pool receives no scoped steering or repo skills.
    kiro = {
      rules = disableRules (
        lib.filterAttrs (_: rule: rule.matcher != null) gen.rules
      );
      skills = noSkills;
    };

    skills = {
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

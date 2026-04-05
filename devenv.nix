{
  pkgs,
  lib,
  ...
}: let
  fragments = import ./lib/fragments.nix {inherit lib;};

  # Build AGENTS.md content from all packages
  devPackages = fragments.packagesWithProfile "dev";
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devPackages;
  agentsBase = fragments.mkInstructions {
    package = "monorepo";
    profile = "dev";
    ecosystem = "agentsmd";
  };
  agentsPackageContent =
    builtins.concatStringsSep "\n"
    (lib.mapAttrsToList
      (pkg: _:
        fragments.mkPackageContent {
          package = pkg;
          profile = "dev";
        })
      nonRootPackages);
  agentsContent =
    agentsBase
    + lib.optionalString (agentsPackageContent != "") ("\n" + agentsPackageContent);

  # Helper: generate files for all ecosystems × packages
  mkEcosystemFiles = let
    mkFiles = package: {
      claude = fragments.mkInstructions {
        inherit package;
        profile = "dev";
        ecosystem = "claude";
      };
      kiro = fragments.mkInstructions {
        inherit package;
        profile = "dev";
        ecosystem = "kiro";
      };
      copilot = fragments.mkInstructions {
        inherit package;
        profile = "dev";
        ecosystem = "copilot";
      };
    };

    root = mkFiles "monorepo";
  in
    {
      ".claude/rules/common.md".text = root.claude;
      ".kiro/steering/common.md".text = root.kiro;
      ".github/copilot-instructions.md".text = root.copilot;
    }
    // (lib.concatMapAttrs (pkg: _: let
        f = mkFiles pkg;
      in {
        ".claude/rules/${pkg}.md".text = f.claude;
        ".kiro/steering/${pkg}.md".text = f.kiro;
        ".github/instructions/${pkg}.instructions.md".text = f.copilot;
      })
      nonRootPackages);
in {
  imports = [
    ./modules/devenv
  ];

  # ── Packages ──────────────────────────────────────────────────────────
  packages = with pkgs; [
    cspell
    deadnix
    nvfetcher
    statix
  ];

  # ── File Generation (from fragments) ─────────────────────────────────
  files =
    mkEcosystemFiles
    // {
      "AGENTS.md".text = ''
        # AGENTS.md

        Project instructions for AI coding assistants working in this repository.
        Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
        support the [AGENTS.md standard](https://agents.md).

        ${agentsContent}
      '';
    };

  # ── treefmt ────────────────────────────────────────────────────────────
  treefmt = {
    enable = true;
    config = import ./treefmt.nix;
  };

  # ── Git Hooks ─────────────────────────────────────────────────────────
  # treefmt hook is auto-wired by treefmt.enable above
  git-hooks.hooks = {
    # Nix linting
    deadnix.enable = true;
    statix.enable = true;

    # Spelling
    cspell.enable = true;

    # Commit message convention
    convco.enable = true;

    # Syntax validation
    check-json.enable = true;
    check-toml.enable = true;
  };

  # ── Claude Code ───────────────────────────────────────────────────────
  claude.code = {
    enable = true;

    permissions.rules = {
      Bash = {
        allow = [
          "devenv *"
          "dprint:*"
          "git absorb*"
          "git add*"
          "git amend*"
          "git branch*"
          "git branchless*"
          "git checkout*"
          "git commit*"
          "git diff*"
          "git fetch*"
          "git hide*"
          "git log*"
          "git move*"
          "git next*"
          "git prev*"
          "git pull*"
          "git push*"
          "git rebase*"
          "git record*"
          "git reset*"
          "git restack*"
          "git revise*"
          "git reword*"
          "git show*"
          "git sl*"
          "git smartlog*"
          "git status*"
          "git stash*"
          "git submit*"
          "git sync*"
          "git test*"
          "git unhide*"
          "head:*"
          "nix *"
          "treefmt *"
          "wc *"
        ];
      };
      Read.allow = ["references/*"];
    };

    mcpServers = {
      devenv = {
        type = "http";
        url = "https://mcp.devenv.sh/mcp";
      };
    };
  };

  # ── MCP Processes (no-cred servers, `devenv up`) ───────────────────────
  # processes = {
  #   nixos-mcp.exec = "${pkgs.nix-mcp-servers.nixos-mcp}/bin/mcp-nixos";
  #   sequential-thinking-mcp.exec = "${pkgs.nix-mcp-servers.sequential-thinking-mcp}/bin/sequential-thinking-mcp";
  # };
  # NOTE: MCP servers are stdio-based, not HTTP daemons. Process management
  # applies when running as HTTP bridges. Uncomment when bridge mode is needed.

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = {
    "update:packages" = {
      exec = "nvfetcher";
      before = [];
    };
  };
}

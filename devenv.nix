{
  pkgs,
  lib,
  inputs,
  ...
}: let
  fragments = import ./lib/fragments.nix {inherit lib;};

  # ── Overlay packages ─────────────────────────────────────────────────
  # devenv's pkgs lacks the flake overlay. Apply git-tools overlay to get
  # agnix (reuses packages/git-tools/ definition, no build duplication).
  gitToolsPkgs = pkgs.extend (import ./packages/git-tools {
    inputs = {
      inherit (inputs) nixpkgs rust-overlay;
    };
  });
  inherit (gitToolsPkgs) agnix;

  # Serena MCP — flake input, not overlay (complex Python deps).
  # Override passthru to carry mcpArgs so mkPackageEntry works.
  serena = let
    upstream = inputs.serena.packages.${pkgs.stdenv.hostPlatform.system}.default;
  in
    upstream.overrideAttrs {passthru.mcpArgs = ["start-mcp-server"];};

  # ── MCP entry helper ─────────────────────────────────────────────────
  # Derive stdio MCP entry from package passthru (single source of truth).
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;

  # Build instruction content from composed fragments
  devPackages = fragments.packagesWithProfile "dev";
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devPackages;

  # Helper: compose fragments for a package profile
  mkComposed = package: profile: let
    prof = fragments.packageProfiles.${package}.${profile};
  in
    fragments.compose {
      fragments =
        map fragments.readCommonFragment prof.common
        ++ map (fragments.readPackageFragment package) prof.package;
    };

  # AGENTS.md content (agentsmd ecosystem = no frontmatter)
  agentsContent = let
    rootComposed = mkComposed "monorepo" "dev";
    packageContents = lib.mapAttrsToList (pkg: _: let
      prof = fragments.packageProfiles.${pkg}."dev";
      pkgOnly = fragments.compose {
        fragments = map (fragments.readPackageFragment pkg) prof.package;
      };
    in
      pkgOnly.text)
    nonRootPackages;
  in
    rootComposed.text
    + lib.optionalString (packageContents != [])
    ("\n" + builtins.concatStringsSep "\n" packageContents);

  # Helper: generate files for all ecosystems × packages
  mkEcosystemFiles = let
    # Generate per-ecosystem file from a composed fragment
    mkEcosystemFile = ecosystem: package: composed: let
      fm = fragments.ecosystems.${ecosystem}.mkFrontmatter package;
      fmStr =
        if fm == null
        then ""
        else fragments.mkFrontmatter fm + "\n";
    in
      fmStr + composed.text;

    rootComposed = mkComposed "monorepo" "dev";
  in
    {
      ".claude/rules/common.md".text = mkEcosystemFile "claude" "monorepo" rootComposed;
      ".kiro/steering/common.md".text = mkEcosystemFile "kiro" "monorepo" rootComposed;
      ".github/copilot-instructions.md".text = mkEcosystemFile "copilot" "monorepo" rootComposed;
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkComposed pkg "dev";
      in {
        ".claude/rules/${pkg}.md".text = mkEcosystemFile "claude" pkg composed;
        ".kiro/steering/${pkg}.md".text = mkEcosystemFile "kiro" pkg composed;
        ".github/instructions/${pkg}.instructions.md".text = mkEcosystemFile "copilot" pkg composed;
      })
      nonRootPackages);
in {
  imports = [
    ./modules/devenv
  ];

  # ── Packages ──────────────────────────────────────────────────────────
  packages =
    (with pkgs; [
      # Dev tools
      cspell
      deadnix
      nvfetcher
      statix

      # LSP servers (in PATH for ENABLE_LSP_TOOL and MCP bridging)
      marksman
      nixd
      taplo
    ])
    ++ [
      # Overlay packages (built from repo sources, not in devenv's pkgs)
      agnix
    ];

  # ── Unified AI Config ─────────────────────────────────────────────────
  ai = {
    enable = true;
    enableClaude = true;
    enableCopilot = true;
    enableKiro = true;

    # Consumer skills (stacked workflows)
    skills = {
      sws-stack-fix = ./packages/stacked-workflows/skills/stack-fix;
      sws-stack-plan = ./packages/stacked-workflows/skills/stack-plan;
      sws-stack-split = ./packages/stacked-workflows/skills/stack-split;
      sws-stack-submit = ./packages/stacked-workflows/skills/stack-submit;
      sws-stack-summary = ./packages/stacked-workflows/skills/stack-summary;
      sws-stack-test = ./packages/stacked-workflows/skills/stack-test;

      # Dev skills
      index-repo-docs = ./dev/skills/index-repo-docs;
      repo-review = ./dev/skills/repo-review;
    };
  };

  # ── File Generation (from fragments) ─────────────────────────────────
  # Fragment-generated instruction files are ecosystem-specific and stay
  # in files.* directly. The ai.* module handles ecosystem-agnostic shared
  # skills; fragments handle per-ecosystem instruction content.
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
    # Nix linting (exclude auto-generated nvfetcher files)
    deadnix = {
      enable = true;
      excludes = [".*\\.nvfetcher/.*"];
    };
    statix = {
      enable = true;
      excludes = [".*\\.nvfetcher/.*"];
    };

    # Spelling
    cspell.enable = true;

    # Commit message convention
    convco.enable = true;

    # Syntax validation
    check-json.enable = true;
    check-toml.enable = true;
  };

  # ── Copilot ────────────────────────────────────────────────────────────
  copilot = {
    enable = true;
    mcpServers = {
      agnix = mkPackageEntry agnix;
      serena = mkPackageEntry serena;
    };
  };

  # ── Kiro ──────────────────────────────────────────────────────────────
  kiro = {
    enable = true;
    mcpServers = {
      agnix = mkPackageEntry agnix;
      serena = mkPackageEntry serena;
    };
  };

  # ── Claude Code ───────────────────────────────────────────────────────
  claude.code = {
    enable = true;

    permissions.rules = {
      Bash = {
        allow = [
          "devenv *"
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
      Read.allow = ["dev/references/*"];
    };

    env.ENABLE_LSP_TOOL = "1";

    mcpServers = {
      agnix = mkPackageEntry agnix;
      serena = mkPackageEntry serena;
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

  # ── Validation ─────────────────────────────────────────────────────────
  enterTest = ''
    echo "Validating devenv configuration..."

    # Check ecosystem instruction files exist
    test -L .claude/rules/common.md || { echo "FAIL: .claude/rules/common.md missing"; exit 1; }
    test -L .kiro/steering/common.md || { echo "FAIL: .kiro/steering/common.md missing"; exit 1; }
    test -L .github/copilot-instructions.md || { echo "FAIL: .github/copilot-instructions.md missing"; exit 1; }
    test -L AGENTS.md || { echo "FAIL: AGENTS.md missing"; exit 1; }

    # Check skills are wired (Claude + Copilot + Kiro)
    test -L .claude/skills/sws-stack-fix || { echo "FAIL: .claude/skills/sws-stack-fix missing"; exit 1; }
    test -L .claude/skills/repo-review || { echo "FAIL: .claude/skills/repo-review missing"; exit 1; }
    test -L .github/skills/sws-stack-fix || { echo "FAIL: .github/skills/sws-stack-fix missing"; exit 1; }
    test -L .kiro/skills/sws-stack-fix || { echo "FAIL: .kiro/skills/sws-stack-fix missing"; exit 1; }

    # Check Claude settings generated
    test -L .claude/settings.json || { echo "FAIL: .claude/settings.json missing"; exit 1; }

    echo "All checks passed"
  '';

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = {
    "update:packages" = {
      exec = "nvfetcher";
      before = [];
    };
  };
}

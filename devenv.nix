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

  # Content packages — apply overlays to get passthru fragments.
  contentPkgs = pkgs.extend (lib.composeManyExtensions [
    (import ./packages/coding-standards {})
    (import ./packages/stacked-workflows {})
  ]);

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

  # ── Fragment composition ─────────────────────────────────────────────
  # Fragments from packages (published content)
  commonFragments = builtins.attrValues contentPkgs.coding-standards.passthru.fragments;

  # Dev-only fragment reader (for this repo's dev instructions)
  mkDevFragment = pkg: name:
    fragments.mkFragment {
      text = builtins.readFile ./dev/fragments/${pkg}/${name}.md;
      description = "dev/${pkg}/${name}";
      priority = 5;
    };

  # Package path scoping (for ecosystem frontmatter)
  packagePaths = {
    ai-clis = ''"modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"'';
    mcp-servers = ''"modules/mcp-servers/**,packages/mcp-servers/**"'';
    monorepo = null;
    stacked-workflows = ''"packages/stacked-workflows/**"'';
  };

  # Dev fragment names per package
  devFragmentNames = {
    ai-clis = ["packaging-guide"];
    monorepo = ["project-overview"];
    mcp-servers = ["overlay-guide"];
    stacked-workflows = ["development" "routing-table"];
  };

  # Compose fragments for a dev package profile
  mkDevComposed = package: let
    devFrags = map (mkDevFragment package) (devFragmentNames.${package} or []);
  in
    fragments.compose {fragments = commonFragments ++ devFrags;};

  # Generate ecosystem file content
  mkEcosystemFile = ecosystem: package: composed:
    fragments.mkEcosystemContent {
      inherit ecosystem package composed;
      paths = packagePaths.${package} or null;
    };

  # ── Instruction file generation ──────────────────────────────────────
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devFragmentNames;

  # AGENTS.md content (agentsmd ecosystem = no frontmatter)
  agentsContent = let
    rootComposed = mkDevComposed "monorepo";
    packageContents = lib.mapAttrsToList (pkg: _: let
      pkgOnly = fragments.compose {
        fragments = map (mkDevFragment pkg) (devFragmentNames.${pkg} or []);
      };
    in
      pkgOnly.text)
    nonRootPackages;
  in
    rootComposed.text
    + lib.optionalString (packageContents != [])
    ("\n" + builtins.concatStringsSep "\n" packageContents);

  # Generate files for all ecosystems x packages
  mkEcosystemFiles = let
    rootComposed = mkDevComposed "monorepo";
  in
    {
      ".claude/rules/common.md".text = mkEcosystemFile "claude" "monorepo" rootComposed;
      ".github/copilot-instructions.md".text = mkEcosystemFile "copilot" "monorepo" rootComposed;
      ".kiro/steering/common.md".text = mkEcosystemFile "kiro" "monorepo" rootComposed;
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
      in {
        ".claude/rules/${pkg}.md".text = mkEcosystemFile "claude" pkg composed;
        ".github/instructions/${pkg}.instructions.md".text = mkEcosystemFile "copilot" pkg composed;
        ".kiro/steering/${pkg}.md".text = mkEcosystemFile "kiro" pkg composed;
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
      sws-stack-fix = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-fix";
      sws-stack-plan = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-plan";
      sws-stack-split = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-split";
      sws-stack-submit = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-submit";
      sws-stack-summary = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-summary";
      sws-stack-test = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-test";

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

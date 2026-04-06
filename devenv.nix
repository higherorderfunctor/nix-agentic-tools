{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ── Overlay packages ─────────────────────────────────────────────────
  # devenv's pkgs lacks the flake overlay. Apply git-tools overlay to get
  # agnix (reuses packages/git-tools/ definition, no build duplication).
  gitToolsPkgs = pkgs.extend (import ./packages/git-tools {
    inputs = {
      inherit (inputs) nixpkgs rust-overlay;
    };
  });
  inherit (gitToolsPkgs) agnix;

  # Content packages — apply stacked-workflows overlay for skills passthru.
  contentPkgs = pkgs.extend (import ./packages/stacked-workflows {});

  # ── MCP entry helper ─────────────────────────────────────────────────
  # Derive stdio MCP entry from package passthru (single source of truth).
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;
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
      mdbook
      nvfetcher
      pagefind
      prefetch-npm-deps
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
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;

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
    cspell = {
      enable = true;
      excludes = [".*-package-lock\\.json$" ".*\\.lock$"];
    };

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
    };
  };

  # ── Kiro ──────────────────────────────────────────────────────────────
  kiro = {
    enable = true;
    mcpServers = {
      agnix = mkPackageEntry agnix;
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

      devenv = {
        type = "http";
        url = "https://mcp.devenv.sh/mcp";
      };
    };
  };

  # ── Processes (`devenv up`) ────────────────────────────────────────────
  processes.docs.exec = "${pkgs.mdbook}/bin/mdbook serve docs/ --open";

  # ── Shell Init ──────────────────────────────────────────────────────────
  # Clean stale skill symlinks pointing to old Nix store paths.
  # devenv files.*.source creates symlinks to store paths; when the
  # store hash changes, the old symlink target is a read-only directory
  # and devenv tries to create inside it instead of replacing it.
  enterShell = ''
    for dir in .claude/skills .github/skills .kiro/skills; do
      if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type l | while read -r link; do
          if [ ! -e "$link" ]; then
            rm -f "$link"
          fi
        done
      fi
    done
  '';

  # ── Validation ─────────────────────────────────────────────────────────
  enterTest = ''
    echo "Validating devenv configuration..."

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
  tasks = let
    updateTasks = (import ./dev/update.nix {inherit lib pkgs;}).tasks;
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib;}).tasks;
  in
    updateTasks
    // generateTasks
    // {
      # Meta task: runs entire update pipeline
      "update:all" = {
        description = "Run full update pipeline";
        after = ["update:verify"];
        exec = ''
          echo "Update pipeline complete"
        '';
      };
    };
}

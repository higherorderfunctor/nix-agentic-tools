{
  pkgs,
  lib,
  inputs,
  ...
}: let
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/kiro-cli/modules/devenv
    ./packages/stacked-workflows/modules/devenv
  ];

  # ── Overlays ──────────────────────────────────────────────────────────
  # devenv applies these to pkgs, so pkgs.ai.*, pkgs.gitTools.*, and
  # pkgs.stacked-workflows-content are available everywhere. No manual
  # overlay composition needed.
  overlays = [
    # Unified AI overlay (pkgs.ai.*, pkgs.gitTools.*)
    (import ./overlays {inherit inputs;})
    # Content packages (pkgs.stacked-workflows-content)
    (import ./packages/stacked-workflows/overlay.nix {})
  ];

  # ── Binary Cache ──────────────────────────────────────────────────────
  cachix.pull = ["nix-agentic-tools"];

  # ── Packages ──────────────────────────────────────────────────────────
  packages = with pkgs; [
    # Dev tools
    cspell
    deadnix
    mdbook
    ninja
    pagefind
    prefetch-npm-deps
    statix

    # LSP servers (in PATH for ENABLE_LSP_TOOL and MCP bridging)
    marksman
    nixd
    taplo

    # Overlay packages — available via pkgs.ai.* after overlay
    pkgs.ai.agnix
  ];

  # ── Unified AI Config ─────────────────────────────────────────────────
  ai = {
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;

    skills = let
      sws = pkgs.stacked-workflows-content.passthru.skillsDir;
    in {
      sws-stack-fix = sws + "/stack-fix";
      sws-stack-plan = sws + "/stack-plan";
      sws-stack-split = sws + "/stack-split";
      sws-stack-submit = sws + "/stack-submit";
      sws-stack-summary = sws + "/stack-summary";
      sws-stack-test = sws + "/stack-test";

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
  git-hooks.hooks = {
    deadnix = {
      enable = true;
      excludes = ["overlays/sources/.*"];
    };
    statix = {
      enable = true;
      excludes = ["overlays/sources/.*"];
    };
    cspell = {
      enable = true;
      excludes = [
        ".*-package-lock\\.json$"
        ".*\\.lock$"
        "^config/cspell/"
        "^docs/human-todo\\.md$"
        "^docs/plan\\.md$"
        "^docs/superpowers/"
      ];
    };
    # Re-stage files modified by formatters (treefmt, shfmt, etc.)
    # Without this, formatters modify staged files but the formatted
    # version isn't re-added — leaving dirty tree after commit.
    treefmt-restage = {
      enable = true;
      name = "treefmt-restage";
      entry = "${pkgs.bash}/bin/bash -c 'git diff --name-only | xargs -r git add'";
      pass_filenames = false;
      stages = ["pre-commit"];
    };
    convco.enable = true;
    shellcheck.enable = true;
    shfmt.enable = true;
    check-json.enable = true;
    check-toml.enable = true;
  };

  # ── Claude Code (upstream devenv options) ───────────────────────────
  claude.code = {
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
      agnix = mkPackageEntry pkgs.ai.mcpServers.agnix-mcp;

      devenv = {
        type = "http";
        url = "https://mcp.devenv.sh/mcp";
      };
    };
  };

  # ── Copilot / Kiro MCP ────────────────────────────────────────────────
  ai.copilot.mcpServers.agnix = {
    type = "stdio";
    package = pkgs.ai.mcpServers.agnix-mcp;
    command = "${pkgs.ai.mcpServers.agnix-mcp}/bin/agnix-mcp";
  };
  ai.kiro.mcpServers.agnix = {
    type = "stdio";
    package = pkgs.ai.mcpServers.agnix-mcp;
    command = "${pkgs.ai.mcpServers.agnix-mcp}/bin/agnix-mcp";
  };

  # ── Processes (`devenv up`) ────────────────────────────────────────────
  processes.docs.exec = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    src=$(nix build .#docs-site --no-link --print-out-paths)
    rm -rf docs/src
    cp -rL "$src" docs/src
    chmod -R u+w docs/src
    ${pkgs.mdbook}/bin/mdbook serve docs/ --open
  '';

  # ── Shell Init ──────────────────────────────────────────────────────────
  enterShell = ''
    for dir in .claude/skills .config/github-copilot/skills .kiro/skills; do
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
    test -f .claude/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .claude/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -f .claude/skills/repo-review/SKILL.md || { echo "FAIL: .claude/skills/repo-review/SKILL.md missing"; exit 1; }
    test -f .config/github-copilot/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .config/github-copilot/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -f .kiro/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .kiro/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -L .claude/settings.json || { echo "FAIL: .claude/settings.json missing"; exit 1; }
    echo "All checks passed"
  '';

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = let
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib;}).tasks;
  in
    generateTasks
    // {
      # ── Update pipeline (ninja DAG) ──────────────────────────────────
      # ninja handles the full dependency graph with -j4 concurrency.
      # Each target runs in a git worktree, cherry-picks to branch on
      # success, rolls back on failure. See scripts/update-*.sh.
      # Targeted updates: ninja -j4 -f .update.ninja update-agnix
      "update:all" = {
        description = "Run full update pipeline (ninja DAG)";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          if [ -n "$(git status --porcelain)" ]; then
            echo "ERROR: working tree is dirty. Commit or stash changes first." >&2
            git status --short >&2
            exit 1
          fi

          # Regenerate ninja build file from flake.lock + update matrix
          nix eval --raw --impure --expr 'import ./config/generate-update-ninja.nix {}' > .update.ninja

          # Clear previous report
          rm -f .update-report.txt

          # Run the DAG
          ninja -j4 -f .update.ninja update-report
        '';
      };
      "build:all" = {
        description = "Build all packages for the current system";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
          echo "Building for $system..."
          # TODO: add .env-based cachix push for local builds
          nix run --inputs-from . nix-fast-build -- \
            --flake ".#packages.$system" \
            --skip-cached \
            --no-nom \
            --no-link
        '';
      };
    };
}

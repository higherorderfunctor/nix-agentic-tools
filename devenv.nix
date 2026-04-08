{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ── Overlay packages ─────────────────────────────────────────────────
  # devenv's pkgs lacks the flake overlay. Compose nvSourcesOverlay
  # (exposes final.nv-sources from .nvfetcher/generated.nix) + the
  # unified ai overlay (post-factory-rollout, all binaries live under
  # pkgs.ai.*). Mirrors the composition in flake.nix so devenv sees
  # the same pkgs.ai.* namespace as consumers.
  nvSourcesOverlay = final: _prev: {
    nv-sources = import ./.nvfetcher/generated.nix {
      inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
    };
  };
  aiPkgs = pkgs.extend (lib.composeManyExtensions [
    nvSourcesOverlay
    (import ./overlays {inherit inputs;})
  ]);
  inherit (aiPkgs.ai) agnix;

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

  # ── Binary Cache ──────────────────────────────────────────────────────
  cachix.pull = ["nix-agentic-tools"];

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
  # Each ai.<cli>.enable is the sole gate and flips the corresponding
  # devenv module enable via mkDefault. No master ai.enable.
  ai = {
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;

    # Consumer skills (stacked workflows). Path addition instead of
    # string interpolation — keeps values as Nix paths so downstream
    # consumers that type-check with `lib.isPath` (including
    # upstream HM `programs.claude-code.skills`) take the correct
    # directory-recursive branch.
    skills = let
      sws = contentPkgs.stacked-workflows-content.passthru.skillsDir;
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

    # Shell linting
    shellcheck.enable = true;
    shfmt.enable = true;

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
  processes.docs.exec = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # Generate site content before serving
    src=$(nix build .#docs-site --no-link --print-out-paths)
    rm -rf docs/src
    cp -rL "$src" docs/src
    chmod -R u+w docs/src
    ${pkgs.mdbook}/bin/mdbook serve docs/ --open
  '';

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

    # Skills use Layout B (real dir containing per-file symlinks)
    # after the mkDevenvSkillEntries walker fanout. The dir exists
    # on disk; SKILL.md inside is a store symlink.
    test -f .claude/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .claude/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -f .claude/skills/repo-review/SKILL.md || { echo "FAIL: .claude/skills/repo-review/SKILL.md missing"; exit 1; }
    test -f .github/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .github/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -f .kiro/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .kiro/skills/sws-stack-fix/SKILL.md missing"; exit 1; }

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

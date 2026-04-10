{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ── Overlay packages ─────────────────────────────────────────────────
  # devenv's pkgs lacks the flake overlay. Compose nvSourcesOverlay
  # (exposes final.nv-sources from .nvfetcher/generated.nix) + the
  # unified ai overlay (post-factory-rollout, binaries live under
  # pkgs.ai.*, pkgs.ai.mcpServers.*, pkgs.ai.lspServers.*, and
  # pkgs.gitTools.*). Mirrors the composition in flake.nix so devenv
  # sees the same namespace as consumers.
  nvSourcesOverlay = final: _prev: {
    nv-sources = import ./.nvfetcher/generated.nix {
      inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
    };
  };
  # Unfree predicate for this repo's devenv only. The overlay's
  # ensureUnfreeCheck guard wraps unfree packages so consumers must
  # opt in. Here we allow the 3 unfree packages for development.
  # Note: nixpkgs `copilot-cli` is AWS Copilot (free, Apache-2.0).
  # Our package is `github-copilot-cli` (GitHub Copilot, unfree).
  aiPkgs =
    (import inputs.nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      config.allowUnfreePredicate = pkg:
        builtins.elem (pkg.pname or "") ["claude-code" "github-copilot-cli" "kiro-cli"];
    }).extend (lib.composeManyExtensions [
      nvSourcesOverlay
      (import ./overlays {inherit inputs;})
    ]);
  inherit (aiPkgs.ai) agnix;
  agnixMcp = aiPkgs.ai.mcpServers.agnix-mcp;

  # Content packages — apply stacked-workflows overlay for skills passthru.
  # overlay.nix is the overlay function (3-arg: inputs: final: prev:).
  # default.nix became a barrel ({ modules = ... }) during factory rollout.
  contentPkgs = pkgs.extend (import ./packages/stacked-workflows/overlay.nix {});

  # ── MCP entry helper ─────────────────────────────────────────────────
  # Derive stdio MCP entry from package passthru (single source of truth).
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;

  # ── Factory lib/pkgs injection ───────────────────────────────────────
  # Factory devenv modules (packages/*/modules/devenv/) call
  # lib.ai.app.devenvTransform and reference pkgs.ai.* for default
  # packages. devenv's module system provides nixpkgs lib (no lib.ai)
  # and un-overlaid pkgs. Wrap each factory import to inject the
  # extended lib and overlay-enriched pkgs.
  aiLib = lib // {ai = import ./lib/ai {inherit lib;};};
  wrapFactory = path: args:
    (import path) (args
      // {
        lib = aiLib;
        pkgs = aiPkgs;
      });
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    (wrapFactory ./packages/claude-code/modules/devenv)
    (wrapFactory ./packages/copilot-cli/modules/devenv)
    (wrapFactory ./packages/kiro-cli/modules/devenv)
    ./packages/stacked-workflows/modules/devenv
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
      # Mirror cspell.json ignorePaths at the pre-commit level.
      # cspell exits 1 when all input files are filtered out by
      # ignorePaths alone, so filtering here (before cspell is
      # invoked) keeps commits that only touch excluded files from
      # failing the hook.
      excludes = [
        ".*-package-lock\\.json$"
        ".*\\.lock$"
        "^docs/human-todo\\.md$"
        "^docs/plan\\.md$"
        "^docs/superpowers/"
      ];
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

  # ── Claude Code (upstream devenv options) ───────────────────────────
  # The factory's mkClaude devenv.config sets claude.code.enable =
  # mkDefault true when ai.claude.enable is on. Claude-specific
  # upstream options (permissions, env, mcpServers) are set here
  # directly — the factory does not yet transform these typed fields
  # through the ai.* pool (tracked by the commonSchema/upstream parity
  # gap in docs/plan.md).
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
      agnix = mkPackageEntry agnixMcp;

      devenv = {
        type = "http";
        url = "https://mcp.devenv.sh/mcp";
      };
    };
  };

  # ── Copilot / Kiro MCP (factory ai.* namespace) ──────────────────────
  # Per-CLI MCP servers use the factory's typed schema (with package
  # field). These flow through devenvTransform → per-app config
  # callbacks → files.*/mcp-config.json. The shared ai.mcpServers pool
  # is NOT used here because it would also flow to Claude's
  # claude.code.mcpServers, hitting an upstream schema mismatch (the
  # commonSchema `package` field is not in devenv's claude.code.mcpServers
  # submodule — see docs/plan.md absorption backlog).
  ai.copilot.mcpServers.agnix = {
    type = "stdio";
    package = agnixMcp;
    command = "${agnixMcp}/bin/agnix-mcp";
  };
  ai.kiro.mcpServers.agnix = {
    type = "stdio";
    package = agnixMcp;
    command = "${agnixMcp}/bin/agnix-mcp";
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

    # Skills use Layout B (real dir containing per-file symlinks)
    # after the mkDevenvSkillEntries walker fanout. The dir exists
    # on disk; SKILL.md inside is a store symlink.
    test -f .claude/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .claude/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
    test -f .claude/skills/repo-review/SKILL.md || { echo "FAIL: .claude/skills/repo-review/SKILL.md missing"; exit 1; }
    test -f .config/github-copilot/skills/sws-stack-fix/SKILL.md || { echo "FAIL: .config/github-copilot/skills/sws-stack-fix/SKILL.md missing"; exit 1; }
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
      # ── Update pipeline tasks ──────────────────────────────────────
      "update:flake" = {
        description = "Update flake.lock (nix flake update)";
        exec = ''
          nix flake update
        '';
      };
      "update:devenv" = {
        description = "Update devenv.lock";
        exec = ''
          devenv update
        '';
      };
      "update:sources" = {
        description = "Update package sources (nvfetcher)";
        exec = ''
          nvfetcher -o .nvfetcher
        '';
      };
      "update:hashes" = {
        description = "Auto-discover and compute dep hashes for overlay packages";
        after = ["update:sources"];
        exec = ''
          bash dev/scripts/update-hashes.sh
        '';
      };
      "update:all" = {
        description = "Run full update pipeline (flake → devenv → sources → hashes)";
        after = ["update:flake" "update:devenv" "update:hashes"];
        exec = ''
          echo "Update pipeline complete"
        '';
      };

      # ── Build tasks ────────────────────────────────────────────────
      "build:all" = {
        description = "Build all packages for the current system and push to cachix";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          system=$(nix eval --raw nixpkgs#system 2>/dev/null || nix eval --impure --raw --expr 'builtins.currentSystem')
          echo "Building for $system..."
          nix-fast-build \
            --flake ".#packages" \
            --systems "$system" \
            --skip-cached \
            --cachix-cache nix-agentic-tools \
            --no-nom \
            --no-link
        '';
      };
    };
}

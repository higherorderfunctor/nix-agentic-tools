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
      # ── Per-input update tasks ──────────────────────────────────────
      # Generated from flake.lock. DAG from follows relationships.
      # Each: nix flake update <input> → regenerate devenv.yaml →
      # devenv update → commit atomically → build + test.
    }
    // (let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      lockNodes = flakeLock.nodes;
      rootInputs = lockNodes.root.inputs;
      inputNames = builtins.attrNames rootInputs;

      # Extract follows deps for DAG ordering
      inputDeps = builtins.listToAttrs (map (name: let
        nodeName = rootInputs.${name};
        node = lockNodes.${nodeName};
        inputs = node.inputs or {};
      in {
        inherit name;
        value =
          if (inputs.nixpkgs or null) == ["nixpkgs"]
          then ["update:input:nixpkgs"]
          else [];
      }) inputNames);

      dirtyGuard = ''
        if [ -n "$(git status --porcelain)" ]; then
          echo "ERROR: working tree is dirty. Commit or stash changes first." >&2
          git status --short >&2
          exit 1
        fi
      '';

      mkInputUpdateTask = name: {
        description = "Update flake input: ${name}";
        after = inputDeps.${name} or [];
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${dirtyGuard}

          echo "Updating input: ${name}"
          nix flake update ${name}

          # Regenerate devenv.yaml with new rev from flake.lock
          nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' > devenv.yaml

          # Sync devenv.lock
          devenv update

          # Atomic commit: flake.lock + devenv.yaml + devenv.lock
          git add flake.lock devenv.yaml devenv.lock
          if ! git diff --staged --quiet; then
            git commit -m "chore: update input ${name}"
          else
            echo "${name}: already up to date"
          fi
        '';
      };

      inputTasks = builtins.listToAttrs (map (name: {
        name = "update:input:${name}";
        value = mkInputUpdateTask name;
      }) inputNames);

      allInputTaskNames = builtins.attrNames inputTasks;
    in
      inputTasks
      // {
        # Meta task: all input updates complete
        "update:inputs" = {
          description = "Update all flake inputs";
          after = allInputTaskNames;
          exec = ''echo "All inputs updated"'';
        };
      })
    // {
      # ── Per-package update tasks ──────────────────────────────────────
      # Each package gets its own task so failures are visible and
      # the DAG can parallelize them in the future (via git worktrees).
    }
    // (let
      system = builtins.currentSystem;
      # Shared preamble for GitHub token
      tokenPreamble = ''
        if [ -z "''${GITHUB_TOKEN:-}" ] && command -v gh &>/dev/null; then
          GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
          [ -n "''${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN
        fi
      '';
      dirtyGuard = ''
        if [ -n "$(git status --porcelain)" ]; then
          echo "ERROR: working tree is dirty. Commit or stash changes first." >&2
          git status --short >&2
          exit 1
        fi
      '';

      # Package update config from shared matrix (single source of truth).
      # CI consumes the same data via nix eval .#updateMatrix.
      # All packages go through nix-update. --use-update-script for
      # per-platform binaries (sources.json). One loop, one mechanism.
      updateMatrix = import ./config/update-matrix.nix;
      inherit (updateMatrix) nixUpdate;

      mkPkgUpdateTask = name: extraArgs: {
        description = "Update ${name} via nix-update";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${tokenPreamble}
          ${dirtyGuard}
          # shellcheck disable=SC2086
          nix run --inputs-from . nix-update -- --flake "${name}" --commit --system "${system}" ${extraArgs}
        '';
      };

      # Sequential via after chains (parallel is unsafe without worktrees).
      orderedPkgs = map (name: {
        inherit name;
        task = mkPkgUpdateTask name nixUpdate.${name};
      }) (builtins.attrNames nixUpdate);

      # Chain: first pkg waits for inputs, each subsequent waits for previous.
      chainedTasks = let
        indexed =
          lib.imap0 (i: entry: {
            name = "update:pkg:${entry.name}";
            value =
              entry.task
              // {
                after =
                  if i == 0
                  then ["update:inputs"]
                  else ["update:pkg:${(builtins.elemAt orderedPkgs (i - 1)).name}"];
              };
          })
          orderedPkgs;
      in
        builtins.listToAttrs indexed;

      allPkgTaskNames = builtins.attrNames chainedTasks;
    in
      chainedTasks
      // {
        # Meta task: all per-package updates complete
        "update:nix-update" = {
          description = "Update all package versions and hashes";
          after = allPkgTaskNames;
          exec = ''echo "All packages updated"'';
        };
      })
    // {
      "update:build" = {
        description = "Build all packages (update pipeline verification)";
        after = ["update:inputs" "update:nix-update"];
        exec = ''devenv tasks run build:all'';
      };
      "update:all" = {
        description = "Run full update pipeline";
        exec = ''devenv tasks run --mode before update:build'';
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

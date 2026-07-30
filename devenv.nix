{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;

  # The four generated instruction-file derivations — same import as
  # flake.nix, single source of truth. Returns { agents, claude, copilot,
  # kiro } (plus gen / fmtDrv / runFmt). Both consumers must render
  # identical bytes: the working tree is materialized from these exact
  # derivations on every shell entry by generate:instructions:materialize,
  # so a second rendering here would flip-flop the tree on every reload.
  instr = import ./dev/instructions.nix {
    inherit lib pkgs;
    inherit (inputs) treefmt-nix;
  };

  # Stop-hook validator (runs the git-hooks suite when Claude hands control
  # back, instead of racing the Edit tool on every PostToolUse). See the
  # claude.code.hooks block below.
  validateAtStop = import ./lib/validate-at-stop.nix {inherit pkgs config;};

  # Pre-commit guard: reject commits made while the default branch is the
  # checked-out HEAD. This repo is trunk-based (see the git-workflow
  # fragment) — `main` is never committed to directly. The branch-protection
  # ruleset already rejects the push, but that only fires after work is done;
  # this catches a mis-branched commit at commit time, in whichever worktree
  # has `main` checked out (normally the primary checkout). It rides the
  # git-hooks framework (never core.hooksPath), so it is SHARED across
  # worktrees but INERT in any worktree not on the trunk.
  # Wired into git-hooks.hooks below.
  rejectDefaultBranchCommit = pkgs.writeShellApplication {
    name = "reject-default-branch-commit";
    runtimeInputs = [pkgs.git];
    text = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # The protected trunk. Hardcoded on purpose: resolving origin/HEAD
      # needs a network round-trip and a configured remote HEAD, neither
      # guaranteed at commit time. If the trunk is ever renamed, edit this
      # one string.
      default_branch="main"
      current_branch="$(git rev-parse --abbrev-ref HEAD)"
      # A detached HEAD prints "HEAD" and every feature branch prints its own
      # name — both are allowed. Only a commit while the default branch is the
      # checked-out HEAD (the one worktree that has main checked out —
      # normally the primary checkout) is rejected. This hook is SHARED across
      # worktrees (it rides the git-hooks framework, never core.hooksPath),
      # but it is INERT in any worktree not on the trunk.
      if [ "$current_branch" = "$default_branch" ]; then
        printf '%s\n' \
          "error: refusing to commit directly on the default branch ('$default_branch')." \
          "This repo is trunk-based — branch into a worktree first, e.g.:" \
          "  worktrees=\"\$(dirname \"\$(git rev-parse --path-format=absolute --git-common-dir)\")-worktrees\"" \
          "  git worktree add -b <type>/<slug> \"\$worktrees/<slug>\" origin/$default_branch" \
          "(--no-verify bypasses this guard by design.)" >&2
        exit 1
      fi
    '';
  };

  # CI-lean closure — EVAL-time branch on $CI. Distinct from the RUNTIME
  # $CI guard in processes.docs.exec below: that one skips work inside an
  # already-built shell; this one changes what the shell closure CONTAINS,
  # so CI never downloads it. Under CI (`devenv test` in
  # .github/workflows/devenv-test.yml) the shell exists only to run the
  # materialize/generate tasks and the enterTest assertions — both use
  # interpolated store paths and never invoke the interactive tooling —
  # so the LSP servers (packages, below) and the git-hooks suite are
  # gated to !CI. The ai.* modules stay ENABLED under CI: their files
  # fanout is exactly what enterTest gates (their CLI wrappers ride
  # along in the closure; gating those needs a factory-level option).
  # devenv evaluates impurely and its eval cache records env-var inputs
  # (devenv-eval-cache EnvInputDesc), so flipping $CI re-evaluates
  # instead of serving a stale shell. With CI unset this config is
  # byte-identical to the pre-gate one; a dev who exports CI=1 in their
  # environment gets the lean shell — accepted.
  isCI = builtins.getEnv "CI" != "";
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/kiro-cli/modules/devenv
    # NOTE: the stacked-workflows and living-workflow devenv modules are NOT
    # imported here. Enabling them would fan their skills into `ai.skills`
    # UNPREFIXED (stack-*, living-workflow) — which, once those packages are
    # installed user-global via nixos-config, the personal-scope copies would
    # silently shadow (Claude precedence: Personal > Project). This dev repo
    # instead wires the same skills directly under a `dev-` prefix (see the
    # `ai.skills` block below) so the in-repo copies are distinctly invocable
    # and not shadowed while developing them.
  ];

  # ── Overlays ──────────────────────────────────────────────────────────
  # devenv applies these to pkgs, so pkgs.ai.*, pkgs.gitTools.*, and
  # pkgs.stacked-workflows-content are available everywhere. No manual
  # overlay composition needed.
  overlays = [
    # Unified AI overlay (pkgs.ai.*, pkgs.gitTools.*)
    (import ./overlays {inherit inputs;})
    # Content packages (pkgs.coding-standards, pkgs.stacked-workflows-content)
    (import ./packages/coding-standards {})
    (import ./packages/stacked-workflows/overlay.nix {})
  ];

  # ── Binary Cache ──────────────────────────────────────────────────────
  cachix.pull = ["nix-agentic-tools"];

  # ── Packages ──────────────────────────────────────────────────────────
  packages = with pkgs;
    [
      # Dev tools
      check-jsonschema
      cspell
      deadnix
      ninja
      prefetch-npm-deps
      statix
    ]
    # LSP servers (in PATH for ENABLE_LSP_TOOL and MCP bridging) —
    # interactive-only, dropped from the CI closure (~1GB: nixd pulls
    # llvm, marksman pulls dotnet). See the isCI note above.
    ++ lib.optionals (!isCI) [
      marksman
      nixd
      taplo
    ]
    ++ [
      # Overlay packages — available via pkgs.ai.* after overlay
      pkgs.ai.agnix
    ];

  # ── Unified AI Config ─────────────────────────────────────────────────
  ai = {
    claude.enable = true;
    copilot.enable = true;
    kiro = {
      enable = true;
      # Launch the v3 engine + new TUI from `devenv shell` (the wrapper appends
      # `--tui --v3` to the kiro-cli launcher). Without this, devenv's kiro-cli
      # ran the legacy engine, so hooks/slash-commands never loaded.
      tui = true;
    };

    skills = let
      # Dev-repo self-consumption. Both the stacked-workflows and
      # living-workflow skills are installed here under a `dev-` prefix so the
      # in-repo copies never collide with — or get shadowed by — the
      # user-global installs of the same skills (Claude precedence: Personal >
      # Project, silent). Consumers and the global installs stay unprefixed
      # (stack-*, living-workflow); only this dev shell prefixes.
      prefixDev = lib.mapAttrs' (name: value: lib.nameValuePair "dev-${name}" value);
      lwSkill = import ./packages/living-workflow/lib/mkSkill.nix {inherit pkgs;};
      traceSource = import ./lib/traceSource.nix {inherit lib;};
    in
      # stacked-workflows: re-key the deref'd, self-contained stack-* skill
      # dirs (real reference files bundled inside each) as dev-stack-*.
      prefixDev pkgs.stacked-workflows-content.passthru.skills
      // {
        # living-workflow: generated with the devenv XDG shell-default state
        # base (devenv has no config.xdg.stateHome), keyed dev-living-workflow.
        dev-living-workflow = lwSkill {
          stateBase = "\${XDG_STATE_HOME:-$HOME/.local/state}/living-workflows";
          src = ./packages/living-workflow/skills/living-workflow;
        };

        # Dev skills (repo-local tooling, not published packages). Wrapped in
        # traceSource.tracedPath so devenv/direnv track their source CONTENTS
        # (a bare `./dir` handed to ai.skills is copied, never read inside, so
        # an edit would otherwise be served from a stale eval cache).
        index-repo-docs = traceSource.tracedPath ./dev/skills/index-repo-docs;
        repo-review = traceSource.tracedPath ./dev/skills/repo-review;
      };
  };

  # ── treefmt ────────────────────────────────────────────────────────────
  treefmt = {
    enable = true;
    config = import ./treefmt.nix;
  };

  # ── Git Hooks ─────────────────────────────────────────────────────────
  #
  # Two-tier validation architecture:
  #
  #   1. Pre-commit (this block, runs on `git commit`):
  #      - Formatters: treefmt (drives biome/taplo/alejandra/etc.)
  #      - Re-stagers: treefmt-restage
  #      - Security trip-wires: gitleaks (catches secrets BEFORE push)
  #      - Commit-message validators: convco
  #      - Code validators (TEMPORARY here): deadnix, statix, cspell,
  #        shellcheck — these belong in agent steering, not pre-commit.
  #        Pre-commit's job is "did I format and not leak secrets",
  #        not "is this code well-typed". The `validate-at-stop` Stop
  #        hook (claude.code, below) now runs these same validators at
  #        each agent hand-back — the first piece of that steering
  #        surface — but they stay here too as the commit-time gate. See
  #        the single-source-of-truth decision in
  #        feedback_validation_entrypoint.md (memory).
  #
  #   2. CI (`nix flake check` in .github/workflows/ci.yml):
  #      - Structural eval checks (cache-hit-parity, factory-eval, etc.)
  #      - Formatting hard gate: checks.<system>.formatting (treefmt --check)
  #      - Package builds (separate `build` job via nix-fast-build)
  #      - `devenv test` (separate `devenv-test` job): runs the
  #        enterTest real-file gate below — the ONLY check on the
  #        gitignored generated instruction files (symlink-vs-copy
  #        class), which no flake check can see.
  #      - NOT the validators above — they're advisory until the
  #        steering migration.
  #
  # If you're an agent reading this and wondering where to add a new
  # validator: think first about whether it belongs in the agent
  # steering (most do) or as a CI hard gate (formatting, security).
  # Pre-commit should stay narrow.
  #
  # Gated to !CI (see the isCI note above): with every hook disabled,
  # devenv's git-hooks integration emits no install/run tasks, so
  # `devenv test` in CI skips the suite — it duplicates the flake-check
  # formatting gate there — and the hook toolchain (gitleaks, convco,
  # per-hook wrappers) drops out of the CI closure. prek itself stays:
  # validate-at-stop carries it as a runtimeInput.
  git-hooks.hooks = lib.optionalAttrs (!isCI) {
    treefmt.enable = true;
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
        "^docs/"
        # Verbatim engine-bundle quotes and real command output, including
        # identifier fragments cut mid-token by windowed byte extraction.
        # Excluded HERE as well as in cspell.json's ignorePaths: pre-commit
        # must filter these itself, because a batch whose every file is
        # ignored leaves `cspell lint` with no files to check and it exits
        # non-zero on that. Authored prose in the same tree stays checked.
        "^fixtures/kiro-primitives/evidence/"
        "^fixtures/kiro-primitives/records/"
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
    shellcheck = {
      enable = true;
      args = ["-x"];
    };
    gitleaks = {
      enable = true;
      name = "gitleaks";
      entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact";
      pass_filenames = false;
      stages = ["pre-commit"];
    };
    # Trunk guard: reject a commit made while the default branch is the
    # checked-out HEAD. always_run so it fires with no file match; INERT on
    # every feature branch (fires only in the worktree that has `main`
    # checked out — normally the primary checkout).
    reject-default-branch-commit = {
      enable = true;
      name = "reject-default-branch-commit";
      entry = lib.getExe rejectDefaultBranchCommit;
      pass_filenames = false;
      always_run = true;
      stages = ["pre-commit"];
    };
  };

  # ── Claude Code (upstream devenv options) ───────────────────────────
  claude.code = {
    # Disable devenv's default PostToolUse git-hooks-run hook. It fired the
    # formatter after Edits, and treefmt's rewrite broke sync with the Edit
    # tool's read-snapshot ("modified since read"). Validation now happens
    # at the Stop boundary via validate-at-stop, where a rewrite has no
    # following Edit to race. Root cause assessed in:
    # docs/plans/prek-posttooluse-hook-feedback-channel.md.
    hooks.git-hooks-run.enable = false;

    # Run the git-hooks suite when Claude hands control back (Stop): auto-fix
    # formatting silently, block-with-reason on judgment lint. See the
    # assessment cited above.
    hooks.validate-at-stop = {
      enable = true;
      name = "validate-at-stop";
      hookType = "Stop";
      command = lib.getExe validateAtStop;
    };

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

  # ── Shell Init ──────────────────────────────────────────────────────────
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
    test -f .claude/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .claude/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    # Deref'd references must resolve on disk (guards the dangling-symlink
    # regression end-to-end, not just at the store-path level).
    test -f .claude/skills/dev-stack-fix/references/git-branchless.md || { echo "FAIL: dev-stack-fix reference git-branchless.md does not resolve"; exit 1; }
    test -f .claude/skills/dev-living-workflow/SKILL.md || { echo "FAIL: .claude/skills/dev-living-workflow/SKILL.md missing"; exit 1; }
    test -f .claude/skills/repo-review/SKILL.md || { echo "FAIL: .claude/skills/repo-review/SKILL.md missing"; exit 1; }
    test -f .github/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .github/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -f .kiro/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .kiro/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -L .claude/settings.json || { echo "FAIL: .claude/settings.json missing"; exit 1; }

    # Generated instruction files must exist as REAL FILES, not symlinks.
    # `test ! -L` is the load-bearing half: `test -f` follows symlinks, so a
    # regression back to devenv files.* symlink mode would still pass a
    # existence-only check while leaving .kiro/steering unreadable to Kiro
    # (it discovers by scanning a directory, and the scan skips symlinks).
    # Three of these groups are gitignored and invisible to every flake
    # check, so this is the only gate on them.
    for f in AGENTS.md CLAUDE.md .claude/rules/nix-standards.md \
             .github/copilot-instructions.md \
             .github/instructions/pipeline.instructions.md \
             .kiro/steering/pipeline.md; do
      test -f "$f" || { echo "FAIL: $f missing"; exit 1; }
      if [ -L "$f" ]; then
        echo "FAIL: $f is a symlink (Kiro cannot follow store symlinks)"
        exit 1
      fi
    done
    echo "All checks passed"
  '';

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = let
    checkTasks = (import ./dev/tasks/check.nix {}).tasks;
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib pkgs instr;}).tasks;
  in
    checkTasks
    // generateTasks
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

          # Regenerate ninja build file from flake.lock + config.update.targets
          nix run .#generate-update-ninja

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
    }
    // lib.optionalAttrs (!isCI) {
      # ── Per-worktree commit-hook config isolation (no-cascade) ───────
      # devenv's git-hooks install bakes an ABSOLUTE --config into the
      # prek-generated hooks (pre-commit, commit-msg), pointing at
      # whichever worktree last entered the shell. The hooks dir is
      # SHARED across every worktree of a clone (one core.hooksPath into
      # the common .git), so it is last-writer-wins: entering worktree
      # B's shell rewrites the hook A commits through, and A then
      # validates against B's config. This is the cross-worktree
      # no-cascade gap.
      #
      # Fix: after install, rewrite that baked --config to resolve the
      # config from the COMMITTING worktree's toplevel at hook-run time.
      # Each worktree validates against its own devenv-generated
      # .pre-commit-config.yaml, and entering one worktree's shell never
      # changes another's commit-time validation.
      #
      # Why not a per-worktree core.hooksPath (physical isolation)?
      # core.hooksPath REPLACES .git/hooks with no fallback, and the
      # shared hooks dir also holds git-branchless's hooks (post-commit,
      # post-rewrite, reference-transaction, post-checkout). Redirecting
      # it per-worktree would stop those firing in linked worktrees,
      # corrupting the shared branchless event log for every worktree
      # commit. Keeping the shared dir + a dynamic config isolates the
      # only thing that actually diverges (the prek config) without
      # touching branchless.
      "hooks:isolate-config" = {
        description = "Make prek hooks resolve their config per-worktree (no-cascade)";
        after = ["devenv:git-hooks:install"];
        before = ["devenv:enterShell"];
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          ${pkgs.git}/bin/git rev-parse --git-dir >/dev/null 2>&1 || exit 0
          hooks_dir="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks)"
          [ -d "$hooks_dir" ] || exit 0

          # Rewrite only prek-generated hooks (they carry a baked
          # --config="<abs>"); git-branchless hooks have neither marker
          # and are left untouched. Idempotent: re-running matches the
          # already-dynamic value and rewrites it to the same text.
          #
          # GNU tools are pinned to store paths (the repo convention) so
          # the rewrite behaves identically on darwin, where a host BSD
          # sed would reject `-i` without a suffix argument. The
          # `$(git ...)` INSIDE the replacement is written verbatim into
          # the hook and runs at COMMIT time under git's own hook
          # environment (git is always on PATH there), so it stays bare —
          # pinning a store path there would break the hook if that path
          # were garbage-collected.
          #
          # The same hooks also get a bootstrap preflight injected ahead
          # of their `exec`. A brand-new worktree has NO
          # .pre-commit-config.yaml at all: it is a devenv `files.*`
          # artifact materialized on shell entry, and `git worktree add`
          # runs no devenv. Left to itself prek then volunteers three
          # remedies (PREK_ALLOW_NO_CONFIG=1, --allow-missing-config,
          # prek uninstall) that all SKIP every check instead of fixing
          # the bootstrap, so the preflight replaces that advice with the
          # correct action. `-f` follows symlinks, so a dangling one (its
          # store path garbage-collected) trips the guard too — the same
          # fix applies. The injected text is POSIX sh: the emitted hook
          # is #!/bin/sh, not bash. Its `$(git ...)` is verbatim hook
          # text for the same reason as the --config rewrite above.
          guard_marker="devenv worktree bootstrap guard"
          IFS= read -r -d "" guard <<'GUARD' || :
          # --- devenv worktree bootstrap guard (hooks:isolate-config) ---
          _devenv_config="$(git rev-parse --show-toplevel)/.pre-commit-config.yaml"
          if [ ! -f "$_devenv_config" ]; then
              echo 'prek: this worktree has not been bootstrapped.' >&2
              echo "  missing: $_devenv_config" >&2
              echo >&2
              echo '  .pre-commit-config.yaml is a devenv files.* artifact: it is' >&2
              echo '  materialized on devenv shell entry, and "git worktree add"' >&2
              echo '  does not run devenv.' >&2
              echo >&2
              echo '  Fix: run "devenv shell" (or any devenv task) in this worktree' >&2
              echo '  once, then commit again.' >&2
              echo >&2
              echo '  Do NOT silence this with PREK_ALLOW_NO_CONFIG=1,' >&2
              echo '  --allow-missing-config, or "prek uninstall". prek suggests' >&2
              echo '  them, but they skip every pre-commit check instead of fixing' >&2
              echo '  the bootstrap.' >&2
              exit 1
          fi
          # --- end devenv worktree bootstrap guard ---
          GUARD

          for hook in "$hooks_dir"/*; do
            [ -f "$hook" ] || continue
            ${pkgs.gnugrep}/bin/grep -q 'prek' "$hook" || continue
            ${pkgs.gnugrep}/bin/grep -q -- '--config=' "$hook" || continue
            ${pkgs.gnused}/bin/sed -i 's#--config="[^"]*"#--config="$(git rev-parse --show-toplevel)/.pre-commit-config.yaml"#' "$hook"

            # Idempotent: the marker gates re-injection, so running this
            # task twice leaves the hooks byte-identical.
            if ${pkgs.gnugrep}/bin/grep -qF -- "$guard_marker" "$hook"; then
              continue
            fi
            tmp="$(${pkgs.coreutils}/bin/mktemp)"
            injected=""
            while IFS= read -r line; do
              case "$line" in
                'exec '*)
                  if [ -z "$injected" ]; then
                    printf '%s' "$guard"
                    injected=1
                  fi
                  ;;
              esac
              printf '%s\n' "$line"
            done <"$hook" >"$tmp"
            # Copy back THROUGH the original inode rather than moving the
            # temp file over it: that preserves the hook's executable bit.
            ${pkgs.coreutils}/bin/cat "$tmp" >"$hook"
            ${pkgs.coreutils}/bin/rm -f "$tmp"
          done
        '';
      };
    };
}

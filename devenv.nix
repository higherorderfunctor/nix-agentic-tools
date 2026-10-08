{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # The same facet assembly the flake uses: the overlay below and the module
  # internals come from it.
  repository = import ./lib/facets/repository.nix {
    inherit inputs;
    root = ./.;
  };
  # One declaration table owns each hook's local and CI lifecycle.
  repoValidation = import ./config/repo-validation.nix {inherit lib pkgs;};
  gitHooksPackages = import "${inputs.git-hooks}/nix" {
    inherit (pkgs) system;
    inherit (inputs) nixpkgs;
    isFlakes = true;
  };
  repoValidationChecks = repoValidation.mkCiChecks {
    gitHooksRun = gitHooksPackages.run;
    src = ./.;
  };

  # Refuses the hand-back while this branch's PR is unfinished. It fails open
  # on any network ambiguity.
  prWatchAtStop = import ./lib/pr-watch-at-stop.nix {inherit pkgs;};

  isolatePrekHooks = import ./lib/isolate-prek-hooks.nix {inherit pkgs;};
  runRepoHooks = pkgs.writeShellApplication {
    name = "run-repo-hooks";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      exec ${lib.getExe config.git-hooks.package} run \
        --hook-stage manual \
        --all-files \
        --config ${config.git-hooks.configFile}
    '';
  };

  # Diagnostic-lean closure — EVAL-time branch on $CI. The manual Devenv
  # Diagnostic workflow sets it to omit interactive LSP/Semble tooling that
  # enterTest never invokes. Validation policy is deliberately NOT conditional:
  # local hooks, their manual-stage projection, and the flake CI projection all
  # exist regardless of $CI, so exporting CI cannot silently make a guard
  # disappear. The ai.* modules stay enabled because enterTest exercises their
  # files fanout (their CLI wrappers ride along in the closure; gating those
  # needs a factory-level option).
  # devenv evaluates impurely and its eval cache records env-var inputs
  # (devenv-eval-cache EnvInputDesc), so flipping $CI re-evaluates
  # instead of serving a stale shell. A developer who exports CI=1 gets the
  # diagnostic-lean interactive tool set, but the same validation declarations.
  isCI = builtins.getEnv "CI" != "";
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/chatgpt-codex/modules/devenv
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/delegate-routing/modules/devenv
    ./packages/kimchi/modules/devenv
    ./packages/kiro-cli/modules/devenv
    ./packages/peer-communication/modules/devenv
    ./packages/semble/modules/devenv
    # This repository's `ai.*` configuration. It consumes `ai.*` exactly as
    # any project would, fed the context and rules dev/generate.nix produces;
    # checks/instructions/instructions-drift.nix evaluates the same module.
    (import ./dev/ai.nix {inherit isCI;})
    # NOTE: the stacked-workflows devenv module is NOT imported here. Enabling
    # it would fan its skills into `ai.skills` UNPREFIXED (stack-*), which, once
    # installed user-global via nixos-config, would silently shadow the
    # project-scope copies (Claude precedence: Personal > Project). This dev
    # repo instead wires the same skills directly under a `dev-` prefix (see the
    # `ai.skills` block in dev/ai.nix) so the in-repo copies remain distinctly
    # invocable.
  ];

  # This repository assembles the modules directly instead of consuming the
  # published devenv wrapper, so provide the same internal values.
  ai.internal = repository.moduleInternals;

  # ── Overlays ──────────────────────────────────────────────────────────
  # devenv applies these to pkgs, so pkgs.ai.* and
  # pkgs.stacked-workflows-content are available everywhere. No manual
  # overlay composition needed. The recipe-level buildOverlay, not the
  # exported one: devenv.yaml pins the same nixpkgs revision with allowUnfree
  # (generated from flake.lock), so it yields the same derivations as the
  # flake's ciPackages without a second nixpkgs evaluation per shell.
  overlays = [repository.buildOverlay];

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
    # Fixture interpreters — `fixtures/kiro-primitives` is operator-run and
    # no flake check executes those suites: no workflow or check references the
    # suites, and devenv.nix itself never invokes either interpreter (the
    # generate tasks and the enterTest assertions use interpolated
    # store paths, per the isCI note above). Same reasoning and same gate as the
    # LSP servers below, kept as its own list so the rationale stays attached to
    # the packages it explains rather than being read as an LSP concern.
    ++ lib.optionals (!isCI) [
      jq
      python3
    ]
    # LSP servers (in PATH for ENABLE_LSP_TOOL and MCP bridging) —
    # interactive-only, dropped from the diagnostic closure (~1GB: nixd pulls
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

  # ── treefmt ────────────────────────────────────────────────────────────
  treefmt = {
    enable = true;
    config = import ./treefmt.nix;
  };

  # ── Git Hooks ─────────────────────────────────────────────────────────
  #
  # `config/repo-validation.nix` is the policy source of truth. It gives the
  # devenv diagnostic hooks a manual stage and leaves commit-message, security,
  # restaging, and trunk guards on their real Git lifecycle only. Flake CI
  # projects its corpus validators from the same declarations.
  git-hooks.hooks = repoValidation.localHooks;
  git-hooks.run = repoValidationChecks.repo-lints;

  # ── Claude Code ─────────────────────────────────────────────────────
  # Only the Stop hook lives here, beside the packages bound above; dev/ai.nix
  # holds the rest of this repository's `ai.*` configuration.
  ai.claude = {
    # The Stop gate is the PR loop. The rule it enforces lived in
    # always-loaded steering and was ignored twice in one session after a
    # mid-session correction, which is the signal that it needed a mechanism
    # rather than more prose.
    hooks.Stop = [
      {
        hooks = [
          {command = lib.getExe prWatchAtStop;}
        ];
      }
    ];
  };

  # ── Validation ─────────────────────────────────────────────────────────
  enterTest = ''
    echo "Validating devenv configuration..."
    nat_codex_bin="$(command -v codex)"
    nat_codex_config=.codex/config.toml
    test -f "$nat_codex_config" || { echo "FAIL: Codex project config was not written"; exit 1; }
    ${pkgs.gnugrep}/bin/grep -Fq 'sandbox_mode = "danger-full-access"' "$nat_codex_config" || { echo "FAIL: Codex project config does not disable the sandbox"; exit 1; }
    ${lib.optionalString (!isCI) ''
      nat_hooks_dir="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks)"
      for nat_hook in pre-commit commit-msg; do
        nat_hook_path="$nat_hooks_dir/$nat_hook"
        ${pkgs.gnugrep}/bin/grep -Fq 'PREK_HOME="$(git rev-parse --show-toplevel)/.devenv/state/prek"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook does not isolate PREK_HOME per worktree"; exit 1; }
        ${pkgs.gnugrep}/bin/grep -Fq -- '--config="$_devenv_config"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook does not resolve the prek config from the launch checkout"; exit 1; }
        ! ${pkgs.gnugrep}/bin/grep -Fq -- '--config="$(git rev-parse --show-toplevel)/.pre-commit-config.yaml"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook still resolves the prek config from the committing worktree"; exit 1; }
      done
    ''}
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      nat_codex_probe_home="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap '${pkgs.coreutils}/bin/rm -rf -- "$nat_codex_probe_home"' EXIT
      # Trusted, as the developer's own Codex home trusts this project: Codex
      # ignores a project `.codex/config.toml` otherwise, and with it the
      # raised `project_doc_max_bytes`.
      printf '[projects."%s"]\ntrust_level = "trusted"\n' "$DEVENV_ROOT" > "$nat_codex_probe_home/config.toml"
      CODEX_HOME="$nat_codex_probe_home" "$nat_codex_bin" debug prompt-input probe > "$nat_codex_probe_home/prompt.json"
      ${pkgs.gnugrep}/bin/grep -Fq -- '- dev-stack-fix:' "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex did not discover dev-stack-fix"; exit 1; }
      # AGENTS.md reaches Codex WHOLE. Codex drops a project document's tail
      # past `project_doc_max_bytes` without a word, so the last line of the
      # file, as the prompt's JSON escapes it, is the proof nothing was cut.
      nat_agents_last="$(${pkgs.gnused}/bin/sed -n '/./h; ''${x;p}' AGENTS.md)"
      nat_agents_last_json="$(${pkgs.jq}/bin/jq -rn --arg line "$nat_agents_last" '$line | tojson | .[1:-1]')"
      ${pkgs.gnugrep}/bin/grep -Fq -- "$nat_agents_last_json" "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex truncated AGENTS.md (its last line is missing from the prompt)"; exit 1; }
      # The index preamble, not its heading: the orientation mentions the
      # heading by name, so the heading alone would pass a truncated file.
      ${pkgs.gnugrep}/bin/grep -Fq -- 'Before editing a path that matches an entry below, read every document listed' "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex did not receive the path-scoped rule index"; exit 1; }
      ${pkgs.gnugrep}/bin/grep -Fq -- '<!-- rule: semble -->' "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex did not receive the Semble CLI rule"; exit 1; }
      # Again with Codex's DEFAULT 32 KiB limit: an untrusted home ignores the
      # project `.codex/config.toml`, as a fresh clone or a linked worktree
      # does. The index and every always-on rule must still arrive; only the
      # orientation's tail may be cut.
      nat_codex_default_home="$nat_codex_probe_home/default"
      ${pkgs.coreutils}/bin/mkdir "$nat_codex_default_home"
      CODEX_HOME="$nat_codex_default_home" "$nat_codex_bin" debug prompt-input probe > "$nat_codex_default_home/prompt.json"
      for nat_needle in 'Before editing a path that matches an entry below, read every document listed' \
                        '<!-- rule: delegate-routing-router -->' \
                        '<!-- rule: semble -->' \
                        '<!-- rule: stacked-workflows-router -->'; do
        ${pkgs.gnugrep}/bin/grep -Fq -- "$nat_needle" "$nat_codex_default_home/prompt.json" || { echo "FAIL: at Codex's default project_doc_max_bytes, AGENTS.md lost '$nat_needle'"; exit 1; }
      done
    )
    echo "All checks passed"
  '';

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = let
    checkTasks = (import ./dev/tasks/check.nix {}).tasks;
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib pkgs;}).tasks;
  in
    checkTasks
    // generateTasks
    // {
      # Keep full-corpus work as named diagnostics. Upstream wires both tasks
      # into activation; detach them because devenv's RunMode::All can traverse
      # from a shared prerequisite into a sibling lane (cachix/devenv#2337).
      # The immutable config lets the manual hook task remain dependency-free.
      "devenv:git-hooks:run" = {
        after = lib.mkForce [];
        before = lib.mkForce [];
        exec = lib.mkForce (lib.getExe runRepoHooks);
      };
      "devenv:treefmt:run".before = lib.mkForce [];

      # ── Update pipeline (ninja DAG) ──────────────────────────────────
      # ninja handles the full dependency graph with -j4 concurrency.
      # Each target runs in a git worktree, cherry-picks to branch on
      # success, rolls back on failure. See scripts/update-*.sh.
      # Targeted updates: ninja -j4 -f .update.ninja update-agnix
      # Reporting-only. Deliberately NOT a git-hooks validator: that table in
      # config/repo-validation.nix requires every validator to carry a CI
      # backend and participate in Stop, which would make this merge-blocking
      # on prose. A false positive there is friction on every documentation
      # edit forever, so it earns promotion by being quiet first.
      "lint:gradeability" = {
        description = "Report steering directives an agent cannot grade itself against (advisory)";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          cd "$DEVENV_ROOT"
          ${pkgs.python3}/bin/python3 checks/repository/gradeability.py .
        '';
      };

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
            --flake ".#ciPackages.$system" \
            --skip-cached \
            --no-nom \
            --no-link
        '';
      };
    }
    // lib.optionalAttrs (!isCI) {
      # ── Commit-hook config resolution (no-cascade) ───────────────────
      # devenv's git-hooks install bakes an ABSOLUTE --config into the
      # prek-generated hooks (pre-commit, commit-msg), pointing at
      # whichever checkout last entered the shell. The hooks dir is
      # SHARED across every worktree of a clone (one core.hooksPath into
      # the common .git), so it is last-writer-wins: entering worktree
      # B's shell rewrites the hook A commits through, and A then
      # validates against B's config. This is the cross-worktree
      # no-cascade gap.
      #
      # Rewrite that --config at hook-run time to use DEVENV_ROOT when it
      # belongs to this repository, or the primary checkout otherwise.
      #
      # This retires the per-worktree bootstrap: a linked worktree that
      # has never seen `devenv shell` commits fine, which is what makes
      # "devenv is never activated in a worktree" workable.
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
        description = "Make prek hooks resolve their config from the launch checkout (no-cascade)";
        after = ["devenv:git-hooks:install"];
        before = ["devenv:enterShell"];
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          exec ${lib.getExe isolatePrekHooks}

        '';
      };
    };
}

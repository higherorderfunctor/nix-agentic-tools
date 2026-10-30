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
  # disappear.
  # devenv evaluates impurely and its eval cache records env-var inputs
  # (devenv-eval-cache EnvInputDesc), so flipping $CI re-evaluates
  # instead of serving a stale shell. A developer who exports CI=1 gets the
  # diagnostic-lean interactive tool set, but the same validation declarations.
  isCI = builtins.getEnv "CI" != "";
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/ai-module/modules/devenv
    ./packages/chatgpt-codex/modules/devenv
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/delegate-routing/modules/devenv
    ./packages/kimchi/modules/devenv
    ./packages/kiro-cli/modules/devenv
    ./packages/microvm/modules/devenv
    ./packages/peer-communication/modules/devenv
    ./packages/semble/modules/devenv
    # Runtime opt-in policy: dev/fragments/pipeline/generation-architecture.md.
    # This repository's `ai.*` configuration. It consumes `ai.*` exactly as
    # any project would, fed the context and rules dev/generate.nix produces;
    # checks/instructions/instructions-drift.nix evaluates the same module.
    (import ./dev/ai.nix {inherit isCI;})
    # Home Manager delivers stacked-workflows skills and its routing rule.
    # Repo-only skills are declared in dev/ai.nix.
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
    # LSP servers (in PATH for editors and MCP bridging) —
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

  # ── Rust ──────────────────────────────────────────────────────────────
  # The shell has no source toolchain pin; explicitly use locked newest stable.
  languages.rust = {
    enable = !isCI;
    lsp.package = config.languages.rust.toolchainPackage;
    toolchainPackage = (import ./lib/toolchains.nix {inherit inputs;}).mkRustToolchain {
      extensions = ["rust-analyzer" "rust-src"];
      inherit pkgs;
      override = "latest";
      pname = "devenv-rust";
    };
  };
  # Cargo searches CARGO_HOME/bin for subcommands; the host's stale cargo-clippy
  # must not shadow this shell's toolchain, even before enterShell adjusts PATH.
  env = lib.optionalAttrs (!isCI) {
    CARGO_HOME = "${config.devenv.state}/cargo";
  };

  # ── treefmt ────────────────────────────────────────────────────────────
  treefmt = {
    enable = true;
    config = import ./treefmt.nix {inherit inputs;};
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
    echo "All checks passed"
  '';

  # ── Tasks ─────────────────────────────────────────────────────────────
  tasks = let
    checkTasks = (import ./dev/tasks/check.nix {}).tasks;
    codeqlTasks = (import ./dev/tasks/codeql.nix {inherit pkgs;}).tasks;
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib pkgs;}).tasks;
  in
    checkTasks
    // codeqlTasks
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

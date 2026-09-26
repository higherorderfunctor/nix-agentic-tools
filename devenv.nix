{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  inherit (mcpLib) mkPackageEntry;

  # One declaration table owns each hook's local, Stop, and CI lifecycle.
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

  # Stop-hook validator (runs the git-hooks suite when Claude hands control
  # back, instead of racing the Edit tool on every PostToolUse). See the
  # claude.code.hooks block below.
  # Refuses the hand-back while this branch's PR is unfinished. Separate from
  # validateAtStop because it answers a different question (is the PR done?)
  # with different failure semantics (fails OPEN on any network ambiguity).
  prWatchAtStop = import ./lib/pr-watch-at-stop.nix {inherit pkgs;};

  validateAtStop = import ./lib/validate-at-stop.nix {
    inherit pkgs config;
    inherit (repoValidation) formatterHookId judgmentHookIds;
  };
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

  # ── ai.shell test vector ───────────────────────────────────────────────
  # Proves, per runtime, that the configured shell actually ARRIVES — against
  # the real artifacts on PATH in this worktree, not against module eval.
  # `checks/ai-shell/module-eval.nix` already covers the option's semantics; what it
  # cannot see is whether the thing a developer's `$PATH` resolves to carries
  # the value. Three runtimes, three different delivery mechanisms, so three
  # different places to look.
  #
  # Copilot is asserted to NOT carry it. That arm is the interesting one: it
  # distinguishes "excluded by design" from "silently failed to deliver",
  # which every positive check alone would conflate. It cross-checks against
  # GIT_SSH_COMMAND, which Copilot's wrapper DOES carry — so the wrapper
  # demonstrably exists and demonstrably received module env, and the absence
  # of SHELL is therefore a real exclusion rather than a dead wrapper.
  #
  # Shared by `devenv test` and the `ai:shell:verify` task so the CI gate and
  # the hand-run check can never disagree.
  expectedShell = lib.getExe pkgs.bash;
  verifyAiShell = pkgs.writeShellApplication {
    name = "verify-ai-shell";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [pkgs.jq pkgs.gnugrep pkgs.coreutils];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      expected=${lib.escapeShellArg expectedShell}
      root="''${DEVENV_ROOT:-$PWD}"
      rc=0
      pass() { printf '  ok    %-8s %s\n' "$1" "$2"; }
      fail() { printf '  FAIL  %-8s %s\n' "$1" "$2" >&2; rc=1; }

      echo "ai.shell test vector — expecting: $expected"

      # Claude: settings.json `env.CLAUDE_CODE_SHELL`. It does NOT read SHELL.
      # `.claude/settings.json` is a `files.*` artifact written on SHELL ENTRY,
      # so running this check alone would read a stale (or absent) file and
      # report a delivery failure that is really a staleness failure. The task
      # declares an edge on `devenv:files` for exactly that reason.
      settings="$root/.claude/settings.json"
      if [ -e "$settings" ]; then
        got="$(jq -r '.env.CLAUDE_CODE_SHELL // ""' "$settings")"
        if [ "$got" = "$expected" ]; then pass claude "CLAUDE_CODE_SHELL in settings.json"
        else fail claude "settings.json CLAUDE_CODE_SHELL='$got'"; fi
      else
        fail claude "no settings.json at $settings"
      fi

      # Codex and Kiro: SHELL baked into the launcher wrapper.
      #
      # BOTH quoting forms must be accepted. makeWrapper's `--set` emits
      # `SHELL='<path>'`; Kiro's hand-written wrapper builds its exports with
      # `escapeShellArg`, which leaves a quote-free store path bare. Matching
      # only the quoted form made this report a false FAILURE against a Kiro
      # wrapper that was carrying the value correctly.
      has_shell() {
        grep -Fq -- "SHELL='$expected'" "$1" || grep -Fq -- "SHELL=$expected" "$1"
      }

      for pair in "codex:codex" "kiro:kiro-cli"; do
        name="''${pair%%:*}"; bin="''${pair##*:}"
        path="$(command -v "$bin" 2>/dev/null || true)"
        if [ -z "$path" ]; then fail "$name" "$bin not on PATH"; continue; fi
        if has_shell "$path"; then pass "$name" "SHELL baked into $bin wrapper"
        else fail "$name" "$bin wrapper does not carry SHELL=$expected"; fi
      done

      # Copilot: excluded on purpose. Cross-checked against GIT_SSH_COMMAND so
      # a missing wrapper cannot masquerade as a clean exclusion.
      cop="$(command -v copilot 2>/dev/null || true)"
      if [ -z "$cop" ]; then
        fail copilot "copilot not on PATH"
      elif ! grep -Fq -- 'GIT_SSH_COMMAND' "$cop"; then
        fail copilot "wrapper carries no module env at all — cannot distinguish exclusion from failure"
      elif has_shell "$cop"; then
        fail copilot "carries SHELL, but Copilot has no shell mapping (should be excluded)"
      else
        pass copilot "correctly excluded (wrapper live, no SHELL)"
      fi

      [ "$rc" -eq 0 ] || { echo "ai.shell test vector FAILED" >&2; exit 1; }
      echo "ai.shell test vector passed"
    '';
  };
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/chatgpt-codex/modules/devenv
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/delegate-sizing/modules/devenv
    ./packages/kimchi/modules/devenv
    ./packages/kiro-cli/modules/devenv
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
    # `ai.skills` block below) so the in-repo copies remain distinctly invocable.
  ];

  # ── Overlays ──────────────────────────────────────────────────────────
  # devenv applies these to pkgs, so pkgs.ai.* and
  # pkgs.stacked-workflows-content are available everywhere. No manual
  # overlay composition needed.
  overlays = [
    (import ./lib/facets/repository.nix {
      inherit inputs;
      root = ./.;
      systems = [pkgs.stdenv.hostPlatform.system];
    }).overlay
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
    # On PATH so `verify-ai-shell` is runnable by name in a worktree, which is
    # the point of a test vector — a check nobody can invoke does not get run.
    # Gated to !CI only because CI reaches it through `enterTest`'s absolute
    # store path and needs nothing on PATH.
    ++ lib.optionals (!isCI) [verifyAiShell]
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
  # `config/repo-validation.nix` is the policy source of truth. It gives Stop
  # participants a manual stage and leaves commit-message, security, restaging,
  # and trunk guards on their real Git lifecycle only. Flake CI projects its
  # corpus validators from the same declarations.
  git-hooks.hooks = repoValidation.localHooks;
  git-hooks.run = repoValidationChecks.repo-lints;

  # ── Claude Code (upstream devenv options) ───────────────────────────
  claude.code = {
    # Disable devenv's default PostToolUse git-hooks-run hook. It fired the
    # formatter after Edits, and treefmt's rewrite broke sync with the Edit
    # tool's read-snapshot ("modified since read"). Validation now happens
    # at the Stop boundary via validate-at-stop, where a rewrite has no
    # following Edit to race. Root cause assessed in:
    # docs/plans/prek-posttooluse-hook-feedback-channel.md.
    hooks = {
      git-hooks-run.enable = false;

      # Run the git-hooks suite when Claude hands control back (Stop): auto-fix
      # formatting silently, block-with-reason on judgment lint. See the
      # assessment cited above.
      validate-at-stop = {
        enable = true;
        name = "validate-at-stop";
        hookType = "Stop";
        command = lib.getExe validateAtStop;
      };

      # Second Stop gate: the PR loop. The rule this enforces lived in
      # always-loaded steering and was ignored twice in one session after a
      # mid-session correction, which is the signal that it needed a mechanism
      # rather than more prose.
      pr-watch-at-stop = {
        enable = true;
        name = "pr-watch-at-stop";
        hookType = "Stop";
        command = lib.getExe prWatchAtStop;
      };
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
      # `**`, not `*`: the references are namespaced one directory deep
      # (dev/references/kimchi-surface/), and a single `*` stops at the
      # separator, so it would silently allow nothing there.
      Read.allow = ["dev/references/**"];
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
    # Shell-entry tasks have finished, so full-corpus validation cannot race
    # materialization. Keep this here rather than in the task DAG: RunMode::All
    # can pull a sibling task through a shared prerequisite during shell entry.
    ${lib.getExe runRepoHooks}
    echo "Validating devenv configuration..."
    # Every enabled `ai.*` runtime must resolve to the binary THIS devenv
    # profile provides, not to whatever the developer has installed
    # user-globally. `claude` and `kimchi` both silently resolved to
    # `~/.nix-profile` until 2026-09-02 — claude because its factory installed
    # on neither backend, kimchi because it was never enabled here.
    #
    # A bare `command -v` cannot catch that: it succeeds either way. Nor is
    # "resolves to a store path" sufficient — a `nix shell` or a second direnv
    # layer also puts store paths on PATH, and both would pass while resolving
    # OUTSIDE this profile. Compare against `$DEVENV_PROFILE/bin` instead, so
    # the assertion is about provenance rather than about path shape.
    test -n "''${DEVENV_PROFILE:-}" || { echo "FAIL: DEVENV_PROFILE is unset; cannot verify runtime provenance"; exit 1; }
    for nat_runtime in claude codex copilot kimchi kiro-cli; do
      nat_runtime_bin="$(command -v "$nat_runtime" || true)"
      test -n "$nat_runtime_bin" || { echo "FAIL: $nat_runtime is not on PATH"; exit 1; }
      nat_runtime_want="$DEVENV_PROFILE/bin/$nat_runtime"
      test -e "$nat_runtime_want" || { echo "FAIL: $nat_runtime is absent from the devenv profile"; exit 1; }
      if [ "$(${pkgs.coreutils}/bin/readlink -f "$nat_runtime_bin")" \
         != "$(${pkgs.coreutils}/bin/readlink -f "$nat_runtime_want")" ]; then
        echo "FAIL: $nat_runtime on PATH is $nat_runtime_bin, not the devenv profile's copy"
        exit 1
      fi
    done

    # Per-runtime ai.shell delivery, against the real artifacts on PATH.
    ${lib.getExe verifyAiShell}
    # Codex must inject no ARGV: a separate `--profile` config layer would make
    # cross-layer permission behavior harder to inspect and validate.
    #
    # It used to assert "is the unwrapped package", which was a proxy for the
    # same thing and stopped being true on 2026-08-10: Codex is now wrapped to
    # carry process ENVIRONMENT (`SHELL` from `ai.shell`, `GIT_SSH_COMMAND`
    # from `gitSshConfigWorkaround`) — see lib/ai/launcher.nix, which Codex's
    # launcher calls with no flags and so only ever emits `--set`. An env-only wrapper cannot reintroduce the
    # profile, so the guard now tests the hazard directly instead of the proxy.
    nat_codex_bin="$(command -v codex)"
    test -n "$nat_codex_bin" || { echo "FAIL: Codex is not on PATH"; exit 1; }
    if ${pkgs.coreutils}/bin/head -c2 "$nat_codex_bin" | ${pkgs.gnugrep}/bin/grep -Fq '#!'; then
      # A generated wrapper script — it must set env and nothing else.
      ! ${pkgs.gnugrep}/bin/grep -Fq -- '--profile' "$nat_codex_bin" || { echo "FAIL: Codex wrapper injects --profile"; exit 1; }
    else
      test "$nat_codex_bin" = "${lib.getExe pkgs.ai.chatgpt-codex}" || { echo "FAIL: Codex on PATH is neither the expected package nor a wrapper for it"; exit 1; }
    fi
    nat_codex_config=.codex/config.toml
    test -f "$nat_codex_config" || { echo "FAIL: Codex project config was not written"; exit 1; }
    ${pkgs.gnugrep}/bin/grep -Fq 'sandbox_mode = "danger-full-access"' "$nat_codex_config" || { echo "FAIL: Codex project config does not disable the sandbox"; exit 1; }
    ! ${pkgs.gnugrep}/bin/grep -Fq '[sandbox_workspace_write]' "$nat_codex_config" || { echo "FAIL: Codex project config retains workspace-write refinements while the sandbox is disabled"; exit 1; }
    ! ${pkgs.gnugrep}/bin/grep -Eq '^(default_permissions|\[permissions)' "$nat_codex_config" || { echo "FAIL: Codex project config mixes named permissions with the sandbox override"; exit 1; }
    test ! -e "''${CODEX_HOME:-$HOME/.codex}/nix-agentic-tools.config.toml" || { echo "FAIL: a stale nix-agentic-tools Codex profile is still materialized in CODEX_HOME"; exit 1; }
    ${lib.optionalString (!isCI) ''
      nat_hooks_dir="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks)"
      for nat_hook in pre-commit commit-msg; do
        nat_hook_path="$nat_hooks_dir/$nat_hook"
        ${pkgs.gnugrep}/bin/grep -Fq 'PREK_HOME="$(git rev-parse --show-toplevel)/.devenv/state/prek"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook does not isolate PREK_HOME per worktree"; exit 1; }
        ${pkgs.gnugrep}/bin/grep -Fq '_devenv_primary="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook does not derive the primary checkout from the common git dir"; exit 1; }
        ${pkgs.gnugrep}/bin/grep -Fq -- '--config="$_devenv_config"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook does not resolve the prek config from the primary checkout"; exit 1; }
        ! ${pkgs.gnugrep}/bin/grep -Fq -- '--config="$(git rev-parse --show-toplevel)/.pre-commit-config.yaml"' "$nat_hook_path" \
          || { echo "FAIL: $nat_hook still resolves the prek config from the committing worktree"; exit 1; }
      done
    ''}
    test -f .claude/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .claude/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    # Deref'd references must resolve on disk (guards the dangling-symlink
    # regression end-to-end, not just at the store-path level).
    test -f .claude/skills/dev-stack-fix/references/git-branchless.md || { echo "FAIL: dev-stack-fix reference git-branchless.md does not resolve"; exit 1; }
    test -f .claude/skills/repo-review/SKILL.md || { echo "FAIL: .claude/skills/repo-review/SKILL.md missing"; exit 1; }
    test -L .agents/skills/dev-stack-fix || { echo "FAIL: .agents/skills/dev-stack-fix is not a skill-directory symlink"; exit 1; }
    test -f .agents/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .agents/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    ${pkgs.gnugrep}/bin/grep -Fq 'name: dev-stack-fix' .agents/skills/dev-stack-fix/SKILL.md || { echo "FAIL: Codex dev-stack-fix metadata is not dev-prefixed"; exit 1; }
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
      ${lib.optionalString (!isCI) ''
      ${pkgs.gnugrep}/bin/grep -Fq -- '<!-- rule: semble -->' "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex did not receive the Semble CLI rule"; exit 1; }
    ''}
    )
    test -f .github/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .github/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -f .kiro/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .kiro/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -L .claude/settings.json || { echo "FAIL: .claude/settings.json missing"; exit 1; }

    # Every instruction file `ai.*` writes here lands where its runtime reads
    # it. Claude's context may link into the store (its loader follows a
    # project CLAUDE.md link); the rest are read-only COPIES. A committed
    # store symlink dangles everywhere else, Claude's scoped-rule loader
    # skips one at project scope, and Kiro steering beside a developer's own
    # stays a file. `test ! -L` is load-bearing because `test -f` follows
    # symlinks. The drift check in `nix flake check` compares the committed
    # bytes without depending on this tree.
    test -f .claude/CLAUDE.md || { echo "FAIL: .claude/CLAUDE.md missing"; exit 1; }
    for f in AGENTS.md .claude/rules/nix-standards.md \
             .github/copilot-instructions.md \
             .github/instructions/pipeline.instructions.md \
             .kiro/steering/pipeline.md; do
      test -f "$f" || { echo "FAIL: $f missing"; exit 1; }
      if [ -L "$f" ]; then
        echo "FAIL: $f is a symlink (ai.* must deliver it as a read-only copy)"
        exit 1
      fi
    done
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
      # The immutable config lets the hook task remain dependency-free while
      # `enterTest` invokes the same helper after shell-entry tasks complete.
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
            --flake ".#packages.$system" \
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
      # Fix: after install, rewrite that baked --config to resolve the
      # config from the PRIMARY CHECKOUT at hook-run time, derived from
      # the shared common git dir. The primary checkout is the one that
      # is entered (sessions launch there and the agent process then
      # runs with cwd in a linked worktree), so its config always exists
      # and always tracks regeneration — while the answer no longer
      # depends on which checkout entered a shell last.
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
      # Hand-run the same per-runtime ai.shell check `devenv test` runs, so a
      # developer can verify delivery in a worktree without the full suite.
      "ai:shell:verify" = {
        description = "Verify ai.shell reaches each runtime in this worktree";
        # Claude's arm reads a `files.*` artifact, which exists only after
        # materialization — without this edge the task fails on staleness and
        # blames delivery.
        after = ["devenv:files"];
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exec ${lib.getExe verifyAiShell}
        '';
      };
      "hooks:isolate-config" = {
        description = "Make prek hooks resolve their config from the primary checkout (no-cascade)";
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

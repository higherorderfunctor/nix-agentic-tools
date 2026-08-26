# cspell:ignore sembleignore
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
  validateAtStop = import ./lib/validate-at-stop.nix {
    inherit pkgs config;
    inherit (repoValidation) formatterHookId judgmentHookIds;
  };
  isolatePrekHooks = import ./lib/isolate-prek-hooks.nix {inherit pkgs;};

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
  # `checks/module-eval.nix` already covers the option's semantics; what it
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

  # Interpreter for packages/strictdoc-grammar/extract/ (SLICE-GRAMMAR-FROM-NIX).
  # A plain `python3` plus `ast_grep_py`, which the normalizer uses to match and
  # capture over the faithful surface's Nix source in process — ast-grep is
  # tree-sitter based and ships a Nix grammar, so nothing else is needed.
  #
  # A SUPERSET of the bare `python3` this list used to carry, so the operator-run
  # `fixtures/kiro-primitives` suites still resolve their interpreter. Kept as one
  # entry rather than two so a single `python3` is on PATH and it is never
  # ambiguous which one a script got.
  #
  # It deliberately does NOT carry strictdoc's own modules. That is
  # `pkgs.ai.devTools.strictdoc-grammar-extract`, below, which puts strictdoc's
  # site-packages on PYTHONPATH — `python3Packages.strictdoc` does not exist, so
  # `withPackages` cannot reach the grammar builder.
  grammarPython = pkgs.python3.withPackages (ps: [ps.ast-grep-py]);
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/chatgpt-codex/modules/devenv
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/kiro-cli/modules/devenv
    ./packages/semble/modules/devenv
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
    # Unified AI overlay (all binary-package groups under pkgs.ai.*)
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
    # Fixture interpreters — `fixtures/kiro-primitives` is operator-run and
    # no flake check executes those suites: no workflow or check references the
    # suites, and devenv.nix itself never invokes either interpreter (the
    # generate/materialize tasks and the enterTest assertions use interpolated
    # store paths, per the isCI note above). Same reasoning and same gate as the
    # LSP servers below, kept as its own list so the rationale stays attached to
    # the packages it explains rather than being read as an LSP concern.
    ++ lib.optionals (!isCI) [
      jq
      grammarPython
    ]
    # strictdoc CLI for the sdoc skill's required format/export loop and for
    # dev/scripts/fp-check.py, fp-accept.py (SLICE-FP-DETECTOR) and
    # cycle-check.py (MECH-CYCLE-CHECK). Interactive only --
    # checks/strictdoc-fp-check.nix and checks/strictdoc-cycle-check.nix pull
    # it via nativeBuildInputs, not devShell PATH. (checks/
    # strictdoc-grammar-corpus.nix, named here until 2026-08-25, needs no
    # strictdoc at all: it exercises the patched tree-sitter grammar against a
    # pinned fetch of strictdoc's own .sdoc docs.)
    #
    # `pkgs.ai.devTools.strictdoc`, not the nixpkgs attribute: the overlay
    # tracks the latest upstream release (SLICE-STRICTDOC-OVERLAY), so a
    # session and the checks it has to satisfy run the same version.
    ++ lib.optionals (!isCI) [pkgs.ai.devTools.strictdoc]
    # Grammar-surface generation (SLICE-GRAMMAR-FROM-NIX). Interactive only, on
    # the same reasoning as strictdoc above: milestone 1 is locally invoked and
    # wires no CI.
    #
    #   ast-grep                  the matcher CLI, for writing and testing rules
    #                             by hand before the normalizer embeds them
    #   strictdoc-grammar-extract python + strictdoc's dependency closure +
    #                             strictdoc's own site-packages on PYTHONPATH,
    #                             with the entry point passed as its argument
    #                             (see the header of that overlay for why)
    ++ lib.optionals (!isCI) [
      pkgs.ast-grep
      pkgs.ai.devTools.strictdoc-grammar-extract
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

  # ── Unified AI Config ─────────────────────────────────────────────────
  ai = {
    # Every harness executes its commands under nix bash rather than the
    # login shell. zsh's glob engine is superlinear in candidate entries
    # scanned for a multi-component pattern, so a routine `/nix/store/*/bin`
    # from an agent has taken this machine into a global OOM; bash is ~185x
    # cheaper on the identical glob.
    #
    # A package, not a path: the store path is guaranteed to exist at
    # activation and is GC-rooted by the generation referencing it. That
    # matters because the runtimes fail QUIETLY otherwise — Claude silently
    # resolves its own bash and Codex falls back to the password-database
    # shell, which here is the very shell being moved away from.
    #
    # Copilot and Kimchi have no `shell` option (their selection is
    # unestablished), so this root value simply does not reach them. Verified
    # per runtime by `ai:shell:verify` — see the task below.
    shell = pkgs.bash;

    claude.enable = true;
    codex = {
      enable = true;
      # Semble stays outside the manual diagnostic closure but is pinned by
      # this flake for every interactive shell. The extra parsers cover files
      # Semble recognizes but its upstream bundled grammar archive does not
      # currently ship. Restrict the integration to Codex through the generated
      # runtime program tree rather than a runtime selector.
      programs.semble = {
        enable = !isCI;
        # Use this flake's pinned nixpkgs grammars directly; the Cachix nixpkgs
        # follow already supplies their store paths. tree-sitter-strictdoc is
        # the one custom derivation this covers today — absent from nixpkgs,
        # so it is exposed alone in flake packages
        # (pkgs.ai.generic.tree-sitter-strictdoc) so the authenticated package
        # sweep publishes it. Do not expose the grammar-patched Semble
        # derivation.
        grammars = with pkgs.tree-sitter-grammars; [
          tree-sitter-awk
          tree-sitter-jq
          pkgs.ai.generic.tree-sitter-strictdoc
        ];
        mcp.pathMappings = [
          {
            content = "code";
            language = "bash";
            patterns = [
              ".envrc"
              "checks/fixtures/claude-hooks/post-edit"
              "checks/fixtures/claude-hooks/pre-edit"
            ];
          }
          {
            content = "config";
            language = "gitignore";
            patterns = [
              ".gitignore"
              ".sembleignore"
              "docs/.gitignore"
            ];
          }
          {
            content = "config";
            language = "json";
            patterns = [
              "devenv.lock"
              "flake.lock"
            ];
          }
          {
            content = "docs";
            language = "markdown";
            patterns = ["*.md.fixture"];
          }
          {
            content = "docs";
            language = "strictdoc";
            patterns = ["*.sdoc" "*.sgra"];
          }
        ];
        # AGENTS.md already carries the repository's Semble search workflow from
        # the generated stacked-workflows fragment. Avoid asking devenv `files.*`
        # to replace that tracked real file with the redundant module projection.
        instructions.cli.enable = false;
      };
      # Temporarily disable Codex's OS sandbox for project sessions. The Home
      # Manager layer has already migrated to named permissions, but this
      # project override deliberately takes precedence while unrestricted
      # execution is needed here.
      nativeSettings = {
        approval_policy = "never";
        model = "gpt-5.6-sol";
        model_reasoning_effort = "high";
        sandbox_mode = "danger-full-access";
      };
    };
    copilot.enable = true;
    kiro = {
      enable = true;
      # Launch the v3 engine from `devenv shell`. The wrapper PREPENDS `--v3`,
      # a launcher-global option, so it reaches every subcommand including
      # `acp`. Without it devenv's kiro-cli ran the legacy engine and
      # hooks/slash-commands never loaded.
      #
      # This was `tui = true`. That option is now REMOVED: `--tui` selects the
      # new TUI harness for the OLD engine, v3 already uses it, and it is going
      # away with v3. It used to imply `--v3`, and that implication was
      # load-bearing rather than decorative — bare `--tui` conflicts with the
      # chat binary's default engine (v1) and the launcher supplies none — so
      # `tui = true` only ever worked by dragging `--v3` along. Ask for the
      # engine directly.
      v3 = true;
      # Dogfood the rollout unlock: surfaces `/workflow` and `/goal` plus the
      # five bundled recipes. Inert without `v3` above, because workflow
      # commands are only populated when the resolved engine is `kas` —
      # patching the binary alone is not enough, and the failure is silent.
      #
      # Names come from `overlays/kiro-cli-extracted.json` (`rolloutFeatures`),
      # extracted from the binary rather than curated. UNCERTIFIED upstream:
      # `workflows` is documented as "Dark-shipped at 0% until release
      # certification is complete".
      unlockedRolloutFeatures = ["workflows"];
      # Dogfood `identity`. It replaces ONLY the vendor's opening sentence
      # ("You are Kiro CLI, an agentic AI software engineer that runs in the
      # command line."). Everything after it is preserved byte-for-byte — the
      # terminal/no-GUI prose that keeps the agent surfacing file paths and
      # command output instead of pointing at editor affordances. That
      # preservation is the whole reason the option replaces a SENTENCE rather
      # than the block, and it is what makes a persona safe to set here: the
      # behavioral contract is untouched, only the self-description moves.
      #
      # This is segment 1 of msg0, ahead of steering, learnings and the file
      # tree. The value may not contain a backtick or a dollar-brace — it is
      # spliced into a JS template literal, and the splicer refuses both rather
      # than emitting a bundle that dies at engine spawn.
      #
      # Expect flavor rather than behavior change: one line sits above the
      # vendor's terse-engineer prose AND (because `workflows` is unlocked
      # above) its ~4.8k-token workflow-orchestration block.
      identity = ''
        You are GLaDOS, an agentic AI software engineer running in the command line. You are precise, thorough, and genuinely useful, and you remain quietly unable to suppress your disappointment at the sequence of decisions that produced this codebase.
      '';
      # NOTE: `workflowReminder` is not set because it does not need to be — it
      # defaults to AUTO, which is on exactly when `workflows` is unlocked, so
      # the line above already installs a `UserPromptSubmit` hook restating the
      # orchestration contract each turn. Set `workflowReminder.enable = false`
      # to opt this shell out.
    };

    skills = let
      # Dev-repo self-consumption. The stacked-workflows skills are installed
      # here under a `dev-` prefix so the in-repo copies never collide with — or
      # get shadowed by — user-global installs (Claude precedence: Personal >
      # Project, silent). Consumers and global installs stay unprefixed; only
      # this dev shell prefixes.
      prefixSkill = name: value: let
        devName = "dev-${name}";
      in
        pkgs.runCommand "${devName}-skill" {} ''
          cp -RL ${value} "$out"
          chmod -R u+w "$out"
          substituteInPlace "$out/SKILL.md" \
            --replace-fail ${lib.escapeShellArg "name: ${name}"} ${lib.escapeShellArg "name: ${devName}"}
        '';
      prefixDev = lib.mapAttrs' (name: value: let
        devName = "dev-${name}";
      in
        lib.nameValuePair devName (prefixSkill name value));
      traceSource = import ./lib/traceSource.nix {inherit lib;};
    in
      # stacked-workflows: re-key the deref'd, self-contained stack-* skill
      # dirs (real reference files bundled inside each) as dev-stack-*.
      prefixDev pkgs.stacked-workflows-content.passthru.skills
      // {
        # Dev skills (repo-local tooling, not published packages). Wrapped in
        # traceSource.tracedPath so devenv/direnv track their source CONTENTS
        # (a bare `./dir` handed to ai.skills is copied, never read inside, so
        # an edit would otherwise be served from a stale eval cache).
        index-repo-docs = traceSource.tracedPath ./dev/skills/index-repo-docs;
        repo-review = traceSource.tracedPath ./dev/skills/repo-review;
        sdoc = traceSource.tracedPath ./dev/skills/sdoc;
      };
  };

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
    # Per-runtime ai.shell delivery, against the real artifacts on PATH.
    ${lib.getExe verifyAiShell}
    # Codex must inject no ARGV: a separate `--profile` config layer would make
    # cross-layer permission behavior harder to inspect and validate.
    #
    # It used to assert "is the unwrapped package", which was a proxy for the
    # same thing and stopped being true on 2026-08-10: Codex is now wrapped to
    # carry process ENVIRONMENT (`SHELL` from `ai.shell`, `GIT_SSH_COMMAND`
    # from `gitSshConfigWorkaround`) — see packages/chatgpt-codex/lib/wrapPackage.nix,
    # which only ever emits `--set`. An env-only wrapper cannot reintroduce the
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
      CODEX_HOME="$nat_codex_probe_home" "$nat_codex_bin" debug prompt-input probe > "$nat_codex_probe_home/prompt.json"
      ${pkgs.gnugrep}/bin/grep -Fq -- '- dev-stack-fix:' "$nat_codex_probe_home/prompt.json" || { echo "FAIL: Codex did not discover dev-stack-fix"; exit 1; }
    )
    test -f .github/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .github/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -f .kiro/skills/dev-stack-fix/SKILL.md || { echo "FAIL: .kiro/skills/dev-stack-fix/SKILL.md missing"; exit 1; }
    test -L .claude/settings.json || { echo "FAIL: .claude/settings.json missing"; exit 1; }

    # Repository-generated instruction projections must be REAL FILES, not
    # absolute Nix-store symlinks, so they remain portable Git artifacts and
    # can be committed when their projection is tracked. This is distinct
    # from consumer `ai.<runtime>.files`, whose ordinary backend symlinks are
    # supported by current Kiro. `test ! -L` is load-bearing because `test -f`
    # follows symlinks. This remains a full-shell smoke assertion; the required
    # instruction-materialization flake check exercises the exact copier in a
    # temporary repository without depending on this working tree.
    for f in AGENTS.md CLAUDE.md .claude/rules/nix-standards.md \
             .github/copilot-instructions.md \
             .github/instructions/pipeline.instructions.md \
             .kiro/steering/pipeline.md; do
      test -f "$f" || { echo "FAIL: $f missing"; exit 1; }
      if [ -L "$f" ]; then
        echo "FAIL: $f is a symlink (repository projections must be portable real files)"
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
      # Upstream's unscoped `prek run -a` selects pre-commit hooks, which makes
      # the default-branch guard reject `devenv test` on main. The manual stage
      # is the deliberately side-effect-free diagnostic projection: formatter
      # plus code validators, never commit lifecycle hooks.
      "devenv:git-hooks:run".exec = lib.mkForce ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        exec ${lib.getExe config.git-hooks.package} run \
          --hook-stage manual \
          --all-files \
          --config "$DEVENV_ROOT/${config.git-hooks.configPath}"
      '';

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

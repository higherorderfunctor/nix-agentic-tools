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

  # Shared shell-hardening settings (bashOptions / shoptHeader /
  # shellcheckFlags) — see config/shell-strict.nix.
  shellStrict = import ./config/shell-strict.nix;

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
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
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

  # Re-stage files changed by formatting hooks without hiding a failure from
  # the producing `git diff`. The previous inline pipeline inherited neither
  # strict mode nor pipefail, so a broken first stage looked like an empty,
  # successful xargs invocation.
  treefmtRestage = pkgs.writeShellApplication {
    name = "treefmt-restage";
    runtimeInputs = [pkgs.findutils pkgs.git];
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
      git diff --name-only -z | xargs -0 -r git add --
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

  # Normalize the repository's canonical checkout and worktree collection from
  # either the main checkout or one of the conventional sibling worktrees, so
  # `worktreesRoot` resolves to the same directory whichever one the shell is
  # entered from. Codex's writable roots are derived from it below.
  #
  # This previously claimed the Codex permission profile granted the shared
  # Git directory "without granting write access to the main checkout's
  # working files". That was never true of the config it described: `extends =
  # ":workspace"` plus `:workspace_roots."." = "write"` made the checked-out
  # working tree writable, measured with `codex sandbox` on 2026-08-05. The
  # claim is recorded here only so it is not reintroduced from memory.
  devenvRoot = toString config.devenv.root;
  devenvRootParent = builtins.dirOf devenvRoot;
  devenvRootParentName = builtins.baseNameOf devenvRootParent;
  repositoryRoot =
    if lib.hasSuffix "-worktrees" devenvRootParentName
    then "${builtins.dirOf devenvRootParent}/${lib.removeSuffix "-worktrees" devenvRootParentName}"
    else devenvRoot;
  worktreesRoot = "${repositoryRoot}-worktrees";
  # The enabled Semble devenv facet owns this project-local cache, contributes
  # it to Codex's writable roots, and invalidates its indexes when the effective
  # Semble package (including extra grammars) changes.
  sembleCache = "${config.devenv.state}/semble-cache";

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
  # It deliberately does NOT carry strictdoc's own modules. That is what
  # `ai.strictdoc.enable` installs — packages/strictdoc-grammar/lib/mkExtract.nix
  # wraps upstream's OWN venv interpreter, because `python3Packages.strictdoc`
  # does not exist and `withPackages` cannot reach the grammar builder.
  grammarPython = pkgs.python3.withPackages (ps: [ps.ast-grep-py]);

  # The typed `.sgra` surface, imported here for ONE reason: its consumer DSL.
  # `ai.strictdoc.grammars.<name>.elements` is declared with the NORMALIZED
  # type, and packages/strictdoc-grammar/values.nix is written against the sugar
  # over it — so the DSL has to be handed in from the call site. Everything else
  # about the surface is the module's business, not this file's.
  sdocGrammar = import ./packages/strictdoc-grammar/lib {inherit lib;};
in {
  imports = [
    ./lib/ai/sharedOptions.nix
    ./packages/chatgpt-codex/modules/devenv
    ./packages/claude-code/modules/devenv
    ./packages/copilot-cli/modules/devenv
    ./packages/kiro-cli/modules/devenv
    ./packages/semble/modules/devenv
    # `ai.strictdoc` (MECH-STRICTDOC-DEVENV-MODULE). Imported by PATH rather
    # than reached through `flake.devenvModules`: the package barrel
    # deliberately does not publish this facet, because checks/options-doc.nix
    # diffs the published devenv option tree against the home-manager one
    # option for option, and this module has no home-manager half by ruling.
    ./packages/strictdoc-grammar/modules/devenv
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
    # nothing in CI reaches it: no workflow and no flake check references those
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
    # strictdoc itself and the grammar-surface runner are NOT listed here. They
    # come from `ai.strictdoc.enable` below, which is the module that owns the
    # wrap. `pkgs.ast-grep` stays: it is the matcher CLI, for writing and
    # testing rules by hand before the normalizer embeds them, and it is not
    # part of the extractor's environment (that one carries ast_grep_py, the
    # library).
    ++ lib.optionals (!isCI) [pkgs.ast-grep]
    # LSP servers (in PATH for ENABLE_LSP_TOOL and MCP bridging) —
    # interactive-only, dropped from the CI closure (~1GB: nixd pulls
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
      # Semble stays outside the CI devenv-test closure but is pinned by this
      # flake for every interactive shell. The extra parsers cover file types
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
      # Keep the project on the legacy sandbox model while the loaded Home
      # Manager user layer still uses it. Named permissions are enabled by the
      # module, but Codex does not compose them with legacy settings across
      # config layers; the user layer must migrate first.
      #
      # `${config.devenv.root}/.git`, the effective Nix cache root, and the
      # project-local Semble cache are contributed automatically once their
      # owning integrations are enabled. Only the worktree collection remains
      # consumer policy here.
      nativeSettings = {
        approval_policy = "never";
        model = "gpt-5.6-sol";
        model_reasoning_effort = "high";
        sandbox_mode = "workspace-write";
        sandbox_workspace_write = {
          network_access = true;
          writable_roots = [
            # The worktree collection, not this checkout: work routinely spans
            # sibling worktrees of one clone, and a session started in any of
            # them must be able to write the others.
            worktreesRoot
          ];
        };
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

    # strictdoc plus the grammar-surface runner
    # (packages/strictdoc-grammar/modules/devenv). Interactive only, on the
    # same reasoning as the LSP servers above: the sdoc skill's format/export
    # loop and milestone one's generation are both locally invoked, and CI
    # reaches strictdoc through nativeBuildInputs on the checks rather than
    # through this shell's PATH.
    #
    # `package` is left at its default, which is deliberate rather than
    # incidental: the two generated layers of the option surface are extracted
    # from ONE strictdoc release's own grammar string, so overriding it
    # type-checks values against a grammar nothing runs.
    strictdoc = {
      enable = !isCI;

      # docs/sdoc/grammar.sgra is GENERATED, by the operator's 2026-08-27
      # ruling on MECH-GRAMMAR-SGRA-NOT-GENERATED: every `.sgra` in this
      # repository comes through this module. Do not hand-edit the file —
      # `nix flake check`'s strictdoc-grammar-model-equal diffs it against
      # what values.nix renders, and it is the render that wins.
      #
      # Write it with: devenv tasks run generate:sgra
      #
      # Declared unconditionally, which costs nothing in CI: the module reads
      # `grammars` only from inside its `mkIf cfg.enable`, so with `enable`
      # false nothing forces `rendered` and no grammar is rendered during a
      # `devenv test`. The flake check renders its own copy from the flake's
      # `self` regardless.
      grammars.repo = {
        target = "docs/sdoc/grammar.sgra";
        elements = import ./packages/strictdoc-grammar/values.nix {
          inherit (sdocGrammar) dsl;
        };
      };
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
        # `\\.` and not `\.`: these are Nix double-quoted strings, where a
        # backslash before a non-escape character is DROPPED, so `\.patch$`
        # reaches cspell as `.patch$` — a regex whose `.` matches any
        # character, quietly excluding every path ending in "patch". Measured:
        # `nix eval --expr '".*\.patch$"'` prints `.*.patch$`. The `.lock` and
        # `-package-lock.json` rows above already double it; the codex row did
        # not, and is corrected here.
        "^overlays/chatgpt-codex-extracted\\.json$"
        # Patch files are verbatim third-party code plus git blob hashes; no
        # token in one is authored here. They were never deliberately checked
        # — oxlint's napi-rs patch merely happened to carry an index hash
        # containing a digit, and regenerating it against a newer dependency
        # produced an all-letter one that cspell reads as a misspelled word.
        # Excluded in both places for the reason given above.
        ".*\\.patch$"
      ];
    };
    # Re-stage files modified by formatters (treefmt, shfmt, etc.)
    # Without this, formatters modify staged files but the formatted
    # version isn't re-added — leaving dirty tree after commit.
    treefmt-restage = {
      enable = true;
      name = "treefmt-restage";
      # -z/-0: a path containing whitespace would otherwise be split into
      # several nonexistent paths and silently left unstaged.
      # `--`: a path beginning with a dash is otherwise parsed as an option —
      # measured, `git add` on a path like `-x.md` dies with an unknown-switch
      # error and stages nothing.
      entry = lib.getExe treefmtRestage;
      pass_filenames = false;
      stages = ["pre-commit"];
    };
    convco.enable = true;
    shellcheck = {
      enable = true;
      args = ["-x"] ++ shellStrict.shellcheckFlags;
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
    ${pkgs.gnugrep}/bin/grep -Fq 'sandbox_mode = "workspace-write"' "$nat_codex_config" || { echo "FAIL: Codex project config does not select the legacy workspace-write sandbox"; exit 1; }
    ! ${pkgs.gnugrep}/bin/grep -Eq '^(default_permissions|\[permissions)' "$nat_codex_config" || { echo "FAIL: Codex project config selects named permissions before the user-layer migration"; exit 1; }
    test ! -e "''${CODEX_HOME:-$HOME/.codex}/nix-agentic-tools.config.toml" || { echo "FAIL: a stale nix-agentic-tools Codex profile is still materialized in CODEX_HOME"; exit 1; }
    # The module-contributed roots. Semble is interactive-only, so its scoped
    # cache is absent from the deliberately lean CI evaluation. `cache/nix` is
    # the regression this convergence fixed: the former permission profile
    # never restated it, so a sandboxed `nix build` here could not write its own
    # cache.
    nat_roots="$(${pkgs.gnugrep}/bin/grep -F 'writable_roots' "$nat_codex_config")"
    for nat_want in ${lib.escapeShellArgs (
      [worktreesRoot]
      ++ lib.optional (!isCI) sembleCache
      ++ ["${devenvRoot}/.git" "cache/nix" "cache/treefmt"]
    )}; do
      case "$nat_roots" in
        *"$nat_want"*) ;;
        *) echo "FAIL: Codex writable_roots is missing $nat_want"; exit 1 ;;
      esac
    done
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
    # follows symlinks. Three groups below are gitignored and invisible to
    # every flake check, so this is the only runtime gate on their projection.
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
    checkTasks = (import ./dev/tasks/check.nix {inherit pkgs;}).tasks;
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

          ${pkgs.git}/bin/git rev-parse --git-dir >/dev/null 2>&1 || exit 0
          hooks_dir="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-path hooks)"
          [ -d "$hooks_dir" ] || exit 0
          exec {isolate_lock_fd}> "$hooks_dir/.devenv-isolate.lock"
          ${lib.getExe pkgs.flock} "$isolate_lock_fd"

          # Rewrite only prek-generated hooks (they carry a baked
          # --config="<abs>"); git-branchless hooks have neither marker
          # and are left untouched.
          #
          # GNU tools are pinned to store paths (the repo convention). The
          # `$(git ...)` INSIDE the injected block is written verbatim into
          # the hook and runs at COMMIT time under git's own hook
          # environment (git is always on PATH there), so it stays bare —
          # pinning a store path there would break the hook if that path
          # were garbage-collected.
          #
          # The shared lock serializes concurrent rewrite tasks. Each complete
          # hook is rendered to a temp file in the hooks directory, receives
          # the original mode, and is published with a same-filesystem rename;
          # a concurrent commit therefore sees either complete generation,
          # never a truncated mixture.
          #
          # The same hooks also get project-local runtime state and a bootstrap
          # preflight injected ahead of their `exec`, and the exec's --config is
          # pointed at the block's `$_devenv_config`. Routing the path through a
          # variable rather than inlining the expression twice keeps ONE source
          # of truth in the hook and — load-bearing — keeps the `--config="…"`
          # sed below idempotent: the primary-checkout expression contains
          # nested double quotes, which `[^"]*` would only match a prefix of, so
          # inlining it would corrupt the exec line on the second rewrite.
          #
          # PREK_HOME stays anchored to the COMMITTING worktree. A devenv
          # shell's PREK_HOME is not inherited by commits launched from an
          # editor or agent, so deriving it here beats falling back to the
          # user-global XDG cache; and under the agent sandbox the primary
          # checkout is a read-only bind while the worktree is the writable one.
          # No `mkdir -p` is needed: prek creates PREK_HOME itself (measured
          # against prek 0.4.12 — a commit into a fresh worktree populated
          # config-tracking.json, hooks/, repos/ and .lock under an absent dir).
          #
          # The bootstrap preflight now names the PRIMARY CHECKOUT, since that
          # is where the config it reads comes from. Left to itself prek
          # volunteers three remedies (PREK_ALLOW_NO_CONFIG=1,
          # --allow-missing-config, prek uninstall) that all SKIP every check
          # instead of fixing the bootstrap, so the preflight replaces that
          # advice with the correct action. `-f` follows symlinks, so a dangling
          # one (its store path garbage-collected) trips the guard too — the
          # same fix applies. The injected text is POSIX sh: the emitted hook is
          # #!/bin/sh, not bash.
          #
          # Idempotent, and migration-safe against the PREVIOUS block shape: the
          # rewrite STRIPS any existing marker-delimited block and re-injects
          # the current one, rather than skipping when a marker is present. A
          # marker check alone would have left worktree-anchored blocks from
          # before this change in place while the exec line started reading
          # their `$_devenv_config` — silently keeping the old semantics.
          guard_begin="# --- devenv worktree bootstrap guard (hooks:isolate-config) ---"
          guard_end="# --- end devenv worktree bootstrap guard ---"
          IFS= read -r -d "" guard_body <<'GUARD' || :
          PREK_HOME="$(git rev-parse --show-toplevel)/.devenv/state/prek"
          export PREK_HOME
          _devenv_primary="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
          _devenv_config="$_devenv_primary/.pre-commit-config.yaml"
          if [ ! -f "$_devenv_config" ]; then
              echo 'prek: the primary checkout has not been bootstrapped.' >&2
              echo "  missing: $_devenv_config" >&2
              echo >&2
              echo '  .pre-commit-config.yaml is a devenv files.* artifact: it is' >&2
              echo '  materialized on devenv shell entry, and neither "git clone"' >&2
              echo '  nor "git worktree add" runs devenv.' >&2
              echo >&2
              echo "  Fix: run \"devenv shell true\" in $_devenv_primary once," >&2
              echo '  then commit again. Linked worktrees need no bootstrap of' >&2
              echo '  their own: they read the primary checkout config.' >&2
              echo >&2
              echo '  Do NOT silence this with PREK_ALLOW_NO_CONFIG=1,' >&2
              echo '  --allow-missing-config, or "prek uninstall". prek suggests' >&2
              echo '  them, but they skip every pre-commit check instead of fixing' >&2
              echo '  the bootstrap.' >&2
              exit 1
          fi
          GUARD

          for hook in "$hooks_dir"/*; do
            [ -f "$hook" ] || continue
            ${pkgs.gnugrep}/bin/grep -q 'prek' "$hook" || continue
            ${pkgs.gnugrep}/bin/grep -q -- '--config=' "$hook" || continue

            tmp="$(${pkgs.coreutils}/bin/mktemp "$hooks_dir/.devenv-hook.XXXXXX")"
            trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
            ${pkgs.gnused}/bin/sed 's#--config="[^"]*"#--config="$_devenv_config"#' "$hook" \
              | {
                in_guard=""
                injected=""
                while IFS= read -r line || [ -n "$line" ]; do
                  if [ -n "$in_guard" ]; then
                    if [ "$line" = "$guard_end" ]; then
                      in_guard=""
                    fi
                    continue
                  fi
                  if [ "$line" = "$guard_begin" ]; then
                    in_guard=1
                    continue
                  fi
                  case "$line" in
                    'exec '*)
                      if [ -z "$injected" ]; then
                        printf '%s\n%s%s\n' "$guard_begin" "$guard_body" "$guard_end"
                        injected=1
                      fi
                      ;;
                  esac
                  printf '%s\n' "$line"
                done
              } >"$tmp"
            # Fail loudly rather than publish an unguarded hook: if prek ever
            # stops emitting a single-line `exec`, the block is stripped and
            # never re-injected, and every commit would silently validate
            # against whatever config prek found on its own. An unterminated
            # block (a hand edit — the atomic rename above cannot produce one)
            # reaches here the same way, since the strip then swallows the
            # `exec` line too, so name both causes rather than only the one
            # this task can distinguish.
            ${pkgs.gnugrep}/bin/grep -qF -- "$guard_begin" "$tmp" || {
              echo "hooks:isolate-config: refusing to install $hook without the bootstrap guard; it has no single-line 'exec', or an unterminated guard block swallowed it" >&2
              exit 1
            }
            ${pkgs.coreutils}/bin/chmod --reference="$hook" "$tmp"
            ${pkgs.coreutils}/bin/mv -f "$tmp" "$hook"
            trap - EXIT
          done
        '';
      };
    };
}

# End-to-end module eval tests. Each test evaluates the full HM module
# (sharedOptions + every package's modules/homeManager) against a
# synthetic config and asserts the resulting option tree + config.
{
  lib,
  pkgs,
  ...
}: let
  # Stub home-manager's lib.hm.dag.* so activation scripts can be
  # declared without importing home-manager. The real activation
  # entries run in a real HM eval context; this is enough to prove
  # the option tree + config block assemble correctly.
  #
  # lib.ai.* mirrors the flake's `baseLib` shape: mcp helpers,
  # fragment helpers, and the app factory primitives are all nested
  # under `lib.ai.*`. No top-level `lib.<helper>` exports exist.
  mcpLib = import ./../lib/mcp.nix {inherit lib;};
  aiBase = import ./../lib/ai {inherit lib;};
  # Generic idempotent-flag helper shared with mkKiro's wrapper (lib/idempotentFlags.nix).
  idempotentFlags = import ./../lib/idempotentFlags.nix {inherit lib;};
  hmLib =
    lib
    // {
      ai =
        aiBase
        // {
          inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig renderServer;
        };
      hm = {
        dag = {
          entryAfter = _: text: {inherit text;};
          entryBefore = _: text: {inherit text;};
        };
      };
    };

  # Stub HM options so the config callback in mkClaude.nix can set
  # home.activation.* and home.file.* without importing all of
  # home-manager. The assertions only check ai.* values; these stubs
  # prevent "option does not exist" errors on the side-effect attrs.
  hmStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      home = {
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
        };
      };
      programs.git.settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      # programs.claude-code is collapsed to attrsOf anything —
      # upstream options aren't in our doc scope (options-doc filters
      # to `ai.*` prefixes), and the stub's only job is to absorb
      # whatever our factory writes. Per-option typed stubs had to be
      # extended every time we added a new `ai.claude.*` route; this
      # freeform form is future-proof.
      programs.claude-code = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      # xdg.stateHome: the living-workflow HM module bakes
      # `config.xdg.stateHome` into its generated skill. Home-manager provides
      # this option in a real eval; stub it here for the module-eval harness.
      xdg.stateHome = lib.mkOption {
        type = lib.types.str;
        default = "/home/test/.local/state";
      };
    };
  };

  # Stub devenv's files option + per-ecosystem upstream options so
  # the config callbacks in the factory can set files.* /
  # claude.code.* / copilot.* / kiro.* without importing devenv.
  devenvStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
      };
      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      enterShell = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      enterTest = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      tasks = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      claude.code = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      copilot = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      kiro = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
    };
  };

  # Stub pkgs.ai with minimal placeholders so factory defaults that
  # reference pkgs.ai.claude-code (default package) can resolve at
  # eval time. The real derivations live in the overlay; here we only
  # need values that stringify cleanly and support passthru access.
  aiStubs =
    (pkgs.ai or {})
    // {
      claude-code = pkgs.ai.claude-code or pkgs.hello;
      copilot-cli = pkgs.ai.copilot-cli or pkgs.hello;
      # Force a tiny `bin/kimchi` stub so the HM wrapper build test is cheap
      # and the wrapProgram target exists (hello has no bin/kimchi).
      kimchi = pkgs.writeShellScriptBin "kimchi" "exec true";
      kiro-cli = pkgs.ai.kiro-cli or pkgs.hello;
      mcpServers = pkgs.ai.mcpServers or {};
      lspServers = pkgs.ai.lspServers or {};
    };

  evalHm = config:
    lib.evalModules {
      specialArgs = {
        lib = hmLib;
        pkgs = pkgs // {ai = aiStubs;};
        inherit (hmLib) hm;
      };
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/claude-code/modules/homeManager
        ./../packages/copilot-cli/modules/homeManager
        ./../packages/kimchi/modules/homeManager
        ./../packages/kiro-cli/modules/homeManager
        ./../packages/living-workflow/modules/homeManager
        ./../packages/mcp-services/modules/homeManager
        ./../packages/stacked-workflows/modules/homeManager
        hmStubs
        {inherit config;}
      ];
    };

  evalDevenv = config:
    lib.evalModules {
      specialArgs = {
        lib = hmLib;
        pkgs = pkgs // {ai = pkgs.ai or {};};
      };
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/claude-code/modules/devenv
        ./../packages/copilot-cli/modules/devenv
        ./../packages/kimchi/modules/devenv
        ./../packages/kiro-cli/modules/devenv
        ./../packages/living-workflow/modules/devenv
        ./../packages/stacked-workflows/modules/devenv
        devenvStubs
        {inherit config;}
      ];
    };

  # STAGE 3 auto-memory generator (packages/kiro-cli/lib/autoMemory.nix). A tiny
  # two-bin stub stands in for the distiller so these emission/parity tests don't
  # depend on building the real overlay package (its bins + behavior are covered
  # by the distiller's own suite and the overlay build).
  kiroMemStub = pkgs.runCommand "kiro-memory-distiller-stub" {} ''
    mkdir -p "$out/bin"
    for b in kiro-memory-distiller kiro-memory-flush kiro-memory-recall; do
      printf '#!/bin/sh\nexit 0\n' > "$out/bin/$b"
      chmod +x "$out/bin/$b"
    done
  '';
  # STAGE 5b: the recall/backend wiring puts openmemory-mem (a bin of openmemory-mcp)
  # on the wrapper PATH. A tiny stub stands in so the eval tests don't build the real
  # MCP server package.
  omMemStub = pkgs.runCommand "openmemory-mcp-stub" {} ''
    mkdir -p "$out/bin"
    printf '#!/bin/sh\nexit 0\n' > "$out/bin/openmemory-mem"
    chmod +x "$out/bin/openmemory-mem"
  '';
  kiroAutoMem = args:
    import ./../packages/kiro-cli/lib/autoMemory.nix ({
        inherit lib;
        pkgs =
          pkgs
          // {
            ai =
              (pkgs.ai or {})
              // {
                kiro-memory-distiller = kiroMemStub;
                mcpServers = (pkgs.ai.mcpServers or {}) // {openmemory-mcp = omMemStub;};
              };
          };
      }
      // args);

  mkTest = name: assertion:
    pkgs.runCommand "module-test-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name}" > $out''
        else throw "FAIL: ${name}"
      }
    '';

  # ── Steering materializer helpers ────────────────────────────────
  # Kiro steering emission migrated from home.file/files.* symlinks to
  # the derived `ai.kiro.steeringFiles` attrset + the shared
  # strategy-driven materializer (lib/ai/materialize.nix). Accessors
  # read the attrset; byte-level checks read the copy writers' heredoc
  # bodies out of the generated scripts.
  matLib = aiBase.materialize;
  hmPruneScript = ev: (ev.config.home.activation."materialize-kiro-steering-prune" or {}).text or "";
  hmWriteScript = ev: (ev.config.home.activation."materialize-kiro-steering-write" or {}).text or "";
  dvTaskExec = ev: ((ev.config.tasks or {})."ai:kiro:materialize-steering" or {}).exec or "";
  # Extract the heredoc body a copy writer embeds for <name> — the
  # #433 heredoc-extraction idiom (see module-kiro-hooks-typed-
  # colocation). The per-script EOF marker is content-hash-derived, so
  # recover it from the `nat_mat_write '<name>' …<<'MARKER'` call line;
  # the script embeds store paths, whose context the split helpers
  # reject, so strip it (byte content is unchanged).
  matHeredocBody = script: name: let
    t = builtins.unsafeDiscardStringContext script;
    parts = lib.splitString "${lib.escapeShellArg name} \"$nat_mat_prev\" <<'" t;
  in
    if builtins.length parts < 2
    then null
    else let
      afterCall = builtins.elemAt parts 1;
      marker = builtins.head (lib.splitString "'\n" afterCall);
      body = lib.removePrefix "${marker}'\n" afterCall;
    in
      builtins.head (lib.splitString "\n${marker}\n" body);
in {
  # ── Kiro launcher wrapper: idempotent --tui/--v3 injection ───────
  # The factory wrapper injects the v3 launch flags; injecting them
  # unconditionally doubles --tui when a caller already passes it (clap
  # aborts). idempotentFlags.nix guards each flag with a per-arg case +
  # conditional `set --`. Cases: both flags (tui⇒v3), v3 alone, neither.
  module-kiro-wrapper-idempotent-both = mkTest "kiro-wrapper-idempotent-both" (
    let
      b = idempotentFlags.idempotentFlagBlock ["--tui" "--v3"];
    in
      lib.hasInfix "nat_seen_tui=0" b
      && lib.hasInfix "nat_seen_v3=0" b
      && lib.hasInfix "--tui) nat_seen_tui=1 ;;" b
      && lib.hasInfix "--v3) nat_seen_v3=1 ;;" b
      && lib.hasInfix ''if [ "$nat_seen_tui" = 0 ]; then set -- "$@" --tui; fi'' b
      && lib.hasInfix ''if [ "$nat_seen_v3" = 0 ]; then set -- "$@" --v3; fi'' b
  );

  module-kiro-wrapper-idempotent-single = mkTest "kiro-wrapper-idempotent-single" (
    let
      b = idempotentFlags.idempotentFlagBlock ["--v3"];
    in
      lib.hasInfix "nat_seen_v3=0" b
      && lib.hasInfix ''if [ "$nat_seen_v3" = 0 ]; then set -- "$@" --v3; fi'' b
      && !(lib.hasInfix "tui" b)
  );

  module-kiro-wrapper-idempotent-none = mkTest "kiro-wrapper-idempotent-none" (
    idempotentFlags.idempotentFlagBlock [] == ""
  );

  module-claude-default-disabled = mkTest "claude-default-disabled" (!(evalHm {}).config.ai.claude.enable);

  module-claude-enable-toggles = mkTest "claude-enable-toggles" (
    let
      ev = evalHm {ai.claude.enable = true;};
    in
      ev.config.ai.claude.enable
  );

  # NOTE: this test verifies that the shared ai.mcpServers pool ACCEPTS
  # an entry when a package module (claude) is also loaded — i.e. no type
  # conflicts between sharedOptions.nix's mcpServers declaration and the
  # per-app one contributed by mkAiApp. It does NOT verify the claude
  # module's internal mergedServers fanout computation. Fanout correctness
  # is tested in checks/factory-eval.nix via factory-mkAiApp-fanout-*.
  # A true end-to-end fanout test requires the rendering pipeline landed
  # in a later milestone (writing mergedServers into home.file output).
  module-claude-shared-mcp-pool-accepted = mkTest "claude-shared-mcp-pool-accepted" (
    let
      evaluated = evalHm {
        ai.claude.enable = true;
        ai.mcpServers.testServer = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      evaluated.config.ai.mcpServers ? testServer
  );

  # Matches the module-claude-shared-mcp-pool-accepted naming precedent:
  # this test verifies the shared ai.mcpServers pool ACCEPTS a context7
  # entry alongside a loaded claude module without type conflicts. It
  # does NOT verify the claude module's internal mergedServers fanout
  # computation — that's covered in checks/factory-eval.nix via the
  # factory-mkAiApp-fanout-* tests.
  module-context7-shared-mcp-pool-accepted = mkTest "context7-shared-mcp-pool-accepted" (
    let
      evaluated = evalHm {
        ai.claude.enable = true;
        ai.mcpServers.ctx = {
          type = "stdio";
          package = pkgs.ai.mcpServers.context7-mcp or pkgs.hello;
          command = "context7-mcp";
        };
      };
    in
      evaluated.config.ai.mcpServers ? ctx
  );

  # Keeps the aihubmix factory from shipping dormant. Asserts more than its
  # context7 sibling below: that the defaults reach the result AND that a
  # consumer override merges on top — `env` is the live surface for
  # AIHUBMIX_API_KEY, since the server has no other config knobs.
  module-aihubmix-factory-call = mkTest "aihubmix-factory-call" (
    let
      mkAihubmix = import ./../packages/aihubmix-mcp/lib/mkAihubmix.nix;
      result =
        mkAihubmix {
          lib = hmLib;
          pkgs = pkgs // {ai = pkgs.ai or {};};
        } {
          env.AIHUBMIX_API_KEY = "sentinel";
        };
    in
      result.type
      == "stdio"
      && result.command == "aihubmix-mcp"
      && result.env.AIHUBMIX_API_KEY == "sentinel"
  );

  module-context7-factory-call = mkTest "context7-factory-call" (
    let
      mkContext7 = import ./../packages/context7-mcp/lib/mkContext7.nix;
      result = mkContext7 {
        lib = hmLib;
        pkgs = pkgs // {ai = pkgs.ai or {};};
      } {};
    in
      result.type == "stdio"
  );

  module-copilot-default-disabled = mkTest "copilot-default-disabled" (!(evalHm {}).config.ai.copilot.enable);

  module-kiro-default-disabled = mkTest "kiro-default-disabled" (!(evalHm {}).config.ai.kiro.enable);

  module-all-three-enabled = mkTest "all-three-enabled" (
    let
      evaluated = evalHm {
        ai = {
          claude.enable = true;
          copilot.enable = true;
          kiro.enable = true;
        };
      };
    in
      evaluated.config.ai.claude.enable
      && evaluated.config.ai.copilot.enable
      && evaluated.config.ai.kiro.enable
  );

  # ── Unnamed-instruction composition ─────────────────────────────
  # Shared-pool UNNAMED instructions compose into the single CLAUDE.md via
  # upstream `programs.claude-code.context` (the generic aggregate home.file
  # writer was retired to end the ~/.claude/CLAUDE.md double-writer collision —
  # see docs/plans/ai-instructions-context-compose-fix.md). Covers
  # sharedOptions.ai.instructions -> mergedInstructions -> composeInstructionsFile
  # -> programs.claude-code.context. (Formerly
  # module-claude-instructions-rendered-to-home-file, which asserted the retired
  # home.file aggregate.)
  module-claude-unnamed-instructions-composed-into-context = mkTest "claude-unnamed-instructions-composed-into-context" (
    let
      evaluated = evalHm {
        ai = {
          claude.enable = true;
          instructions = [
            {
              text = "Always use rg instead of grep.";
              description = "Grep replacement";
            }
          ];
        };
      };
      ctx = evaluated.config.programs.claude-code.context or "";
    in
      lib.hasInfix "Always use rg instead of grep." ctx
      && lib.hasInfix "description: Grep replacement" ctx
      && !(evaluated.config.home.file ? ".claude/CLAUDE.md")
  );

  module-claude-no-instructions-no-file = mkTest "claude-no-instructions-no-file" (
    let
      evaluated = evalHm {ai.claude.enable = true;};
      # With no instructions and no context merged, nothing writes the
      # `home.file` CLAUDE.md path (the generic aggregate writer is retired;
      # context flows through programs.claude-code.context instead). Regression
      # guard that the aggregate stays gone.
    in
      !(evaluated.config.home.file ? ".claude/CLAUDE.md")
  );

  # Per-app (ai.claude.instructions) UNNAMED entries also compose into
  # programs.claude-code.context. (Formerly
  # module-claude-per-app-instructions-rendered, which asserted the home.file
  # aggregate.)
  module-claude-per-app-unnamed-composed-into-context = mkTest "claude-per-app-unnamed-composed-into-context" (
    let
      evaluated = evalHm {
        ai.claude = {
          enable = true;
          instructions = [
            {
              text = "Claude-specific rule.";
              description = "Claude only";
            }
          ];
        };
      };
      ctx = evaluated.config.programs.claude-code.context or "";
    in
      lib.hasInfix "Claude-specific rule." ctx
      && !(evaluated.config.home.file ? ".claude/CLAUDE.md")
  );

  # ── Compose fix (docs/plans/ai-instructions-context-compose-fix.md §6a) ──
  # Claude HM: `context` + one NAMED + one UNNAMED instruction must lower to a
  # SINGLE always-on writer — upstream `programs.claude-code.context` composed
  # as [context baseline] + [unnamed instruction] — with the NAMED entry living
  # ONLY in `.claude/rules/<name>.md`, never duplicated into the composed
  # context. This fills the §4 blind spot (no fixture ever set context + an
  # instruction together for an aggregate CLI), which is why the ~/.claude/
  # CLAUDE.md double-writer collision shipped green.
  #
  # RED today: the generic aggregate (hmTransform:166) writes
  # `home.file.".claude/CLAUDE.md"` whenever any instruction is merged (the
  # second writer that collides with upstream context in a real HM eval), and
  # `programs.claude-code.context` carries only the bare context — so (a) and
  # (b) both fail. GREEN once the aggregate is retired and context composes.
  module-claude-hm-compose-context-and-unnamed = mkTest "claude-hm-compose-context-and-unnamed" (
    let
      evaluated = evalHm {
        ai = {
          claude = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      ctx = evaluated.config.programs.claude-code.context or "";
      aggregate = evaluated.config.home.file.".claude/CLAUDE.md" or null;
      ruleFile = evaluated.config.home.file.".claude/rules/named-rule.md" or null;
    in
      # (a) no generic-aggregate writer on CLAUDE.md — context owns it (upstream).
      aggregate
      == null
      # (b) the single composed context holds BOTH baseline AND the unnamed text.
      && lib.hasInfix "CONTEXT-BASELINE-TOKEN." ctx
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." ctx
      # (c) the named entry lives only in its rules file, not duplicated into context.
      && ruleFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (ruleFile.text or "")
      && !(lib.hasInfix "NAMED-RULE-BODY-TOKEN." ctx)
  );

  # Claude devenv parity (§6a.2). devenv Claude has NO context writer today —
  # its `.claude/CLAUDE.md` came only from the generic aggregate, which drops
  # context (the §2 secondary bug, devenv side) and duplicates the named entry.
  # RED today: the composed file must hold the context baseline (dropped today)
  # and must NOT duplicate the named body (present in the aggregate today).
  module-claude-devenv-compose-context-and-unnamed = mkTest "claude-devenv-compose-context-and-unnamed" (
    let
      evaluated = evalDevenv {
        ai = {
          claude = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      composed = (evaluated.config.files.".claude/CLAUDE.md" or {}).text or "";
      ruleFile = evaluated.config.files.".claude/rules/named-rule.md" or null;
    in
      lib.hasInfix "CONTEXT-BASELINE-TOKEN." composed
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." composed
      && !(lib.hasInfix "NAMED-RULE-BODY-TOKEN." composed)
      && ruleFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (ruleFile.text or "")
  );

  # Copilot HM parity (§6a.3). The single native context file
  # (`.copilot/copilot-instructions.md`) must hold context + unnamed; there must
  # be NO aggregate at `.config/github-copilot/copilot-instructions.md`; named →
  # `.github/instructions/<name>.instructions.md`. RED today: the context writer
  # carries only context (unnamed missing) and the aggregate file exists.
  module-copilot-hm-compose-context-and-unnamed = mkTest "copilot-hm-compose-context-and-unnamed" (
    let
      evaluated = evalHm {
        ai = {
          copilot = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      contextFile = (evaluated.config.home.file.".copilot/copilot-instructions.md" or {}).text or "";
      instrFile = evaluated.config.home.file.".github/instructions/named-rule.instructions.md" or null;
    in
      lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile
      && !(evaluated.config.home.file ? ".config/github-copilot/copilot-instructions.md")
      && instrFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (instrFile.text or "")
  );

  # Copilot devenv parity (§6a.3). Native context file is `.github/copilot-instructions.md`
  # (projectDir = .github). Same shape: holds context + unnamed, no aggregate.
  module-copilot-devenv-compose-context-and-unnamed = mkTest "copilot-devenv-compose-context-and-unnamed" (
    let
      evaluated = evalDevenv {
        ai = {
          copilot = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      contextFile = (evaluated.config.files.".github/copilot-instructions.md" or {}).text or "";
      instrFile = evaluated.config.files.".github/instructions/named-rule.instructions.md" or null;
    in
      lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile
      && !(evaluated.config.files ? ".config/github-copilot/copilot-instructions.md")
      && instrFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (instrFile.text or "")
  );

  # Kiro HM parity (§6a.4). Directory-native: context stays standalone in
  # the `AGENTS.md` steering entry (context only); named → `<name>.md`;
  # unnamed → a DEDICATED `instructions.md`; and NO stray path-shaped
  # key (the old trailing-slash `.config/kiro/steering/` aggregate).
  # Accessors read the derived ai.kiro.steeringFiles attrset (emission
  # is via the strategy-driven materializer).
  module-kiro-hm-compose-context-and-unnamed = mkTest "kiro-hm-compose-context-and-unnamed" (
    let
      evaluated = evalHm {
        ai = {
          kiro = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      steering = evaluated.config.ai.kiro.steeringFiles;
      contextFile = (steering."AGENTS.md" or {}).text or "";
      instrFile = steering."instructions.md" or null;
      namedFile = steering."named-rule.md" or null;
    in
      lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
      && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
      && instrFile != null
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." (instrFile.text or "")
      && !(lib.any (n: lib.hasInfix "/" n) (lib.attrNames steering))
      && namedFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
  );

  # Kiro devenv parity (§6a.4). Same shape against the devenv eval's
  # steeringFiles.
  module-kiro-devenv-compose-context-and-unnamed = mkTest "kiro-devenv-compose-context-and-unnamed" (
    let
      evaluated = evalDevenv {
        ai = {
          kiro = {
            enable = true;
            context = "CONTEXT-BASELINE-TOKEN.";
          };
          instructions = [
            {
              name = "named-rule";
              text = "NAMED-RULE-BODY-TOKEN.";
              paths = ["src/**"];
            }
            {
              text = "UNNAMED-INSTR-TOKEN.";
              description = "unnamed always-on";
            }
          ];
        };
      };
      steering = evaluated.config.ai.kiro.steeringFiles;
      contextFile = (steering."AGENTS.md" or {}).text or "";
      instrFile = steering."instructions.md" or null;
      namedFile = steering."named-rule.md" or null;
    in
      lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
      && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
      && instrFile != null
      && lib.hasInfix "UNNAMED-INSTR-TOKEN." (instrFile.text or "")
      && !(lib.any (n: lib.hasInfix "/" n) (lib.attrNames steering))
      && namedFile != null
      && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
  );

  # ── Task 3 (A2): Claude HM/devenv fanout absorption ────────────
  module-claude-hm-delegates-programs-claude-code = mkTest "claude-hm-delegates-programs-claude-code" (
    let
      result = evalHm {
        ai.claude.enable = true;
      };
    in
      result.config.programs.claude-code.enable or false
  );

  # HM: ai.claude.settings.<key> reaches programs.claude-code.settings.<key>
  # via the transitional raw-inherit in mkClaude.nix. Regression guard for
  # the inherit; will update to assert translation semantics when HM migrates
  # to the devenv pattern.
  module-claude-hm-settings-reach-upstream = mkTest "claude-hm-settings-reach-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings = {
            effortLevel = "medium";
            permissions.allow = ["Read"];
          };
        };
      };
      upstreamSettings = result.config.programs.claude-code.settings or {};
    in
      (upstreamSettings.effortLevel or null)
      == "medium"
      && ((upstreamSettings.permissions.allow or []) == ["Read"])
  );

  # Strict enum: an invalid effortLevel must throw at eval.
  module-claude-hm-effort-level-rejects-invalid = mkTest "claude-hm-effort-level-rejects-invalid" (
    let
      attempt = builtins.tryEval (
        let
          ev = evalHm {
            ai.claude = {
              enable = true;
              settings.effortLevel = "ultra";
            };
          };
        in
          builtins.deepSeq ev.config.ai.claude.settings.effortLevel
          ev.config.ai.claude.settings.effortLevel
      );
    in
      attempt.success == false
  );

  # Valid effortLevel reaches upstream.
  module-claude-hm-effort-level-valid-reaches-upstream = mkTest "claude-hm-effort-level-valid-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.effortLevel = "xhigh";
        };
      };
    in
      (result.config.programs.claude-code.settings.effortLevel or null) == "xhigh"
  );

  # Strict enum: an invalid tui renderer must throw at eval.
  module-claude-hm-tui-rejects-invalid = mkTest "claude-hm-tui-rejects-invalid" (
    let
      attempt = builtins.tryEval (
        let
          ev = evalHm {
            ai.claude = {
              enable = true;
              settings.tui = "curses";
            };
          };
        in
          builtins.deepSeq ev.config.ai.claude.settings.tui
          ev.config.ai.claude.settings.tui
      );
    in
      attempt.success == false
  );

  # Valid tui renderer reaches upstream (typed nullOr enum).
  module-claude-hm-tui-valid-reaches-upstream = mkTest "claude-hm-tui-valid-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.tui = "fullscreen";
        };
      };
    in
      (result.config.programs.claude-code.settings.tui or null) == "fullscreen"
  );

  # Attribution: `false` coerces to "" at the type layer (disables the
  # commit trailer) and survives the null-filter (filterNulls keeps "").
  module-claude-hm-attribution-false-disables-reaches-upstream = mkTest "claude-hm-attribution-false-disables-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.attribution.commit = false;
        };
      };
    in
      (result.config.programs.claude-code.settings.attribution.commit or null) == ""
  );

  # Attribution: a custom string passes through unchanged.
  module-claude-hm-attribution-string-reaches-upstream = mkTest "claude-hm-attribution-string-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.attribution.pr = "Reviewed-by: me";
        };
      };
    in
      (result.config.programs.claude-code.settings.attribution.pr or null) == "Reviewed-by: me"
  );

  # Attribution: `true` coerces to null -> filtered; the attribution block
  # collapses to empty and is dropped entirely (Claude keeps its defaults).
  module-claude-hm-attribution-true-filtered = mkTest "claude-hm-attribution-true-filtered" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.attribution.commit = true;
        };
      };
      s = result.config.programs.claude-code.settings or {};
    in
      !(s ? attribution)
  );

  # Null typed keys are filtered out — upstream never sees the typed keys
  # when unset, and the undocumented `ultracode` key is never written unless
  # ultracodeOnLaunch is set.
  module-claude-hm-null-settings-filtered = mkTest "claude-hm-null-settings-filtered" (
    let
      result = evalHm {ai.claude.enable = true;};
      s = result.config.programs.claude-code.settings or {};
    in
      !(s ? attribution)
      && !(s ? effortLevel)
      && !(s ? model)
      && !(s ? tui)
      && !(s ? enableWorkflows)
      && !(s ? workflowKeywordTriggerEnabled)
      && !(s ? ultracode)
  );

  # Valid enableWorkflows reaches upstream (typed nullOr bool).
  module-claude-hm-enable-workflows-valid-reaches-upstream = mkTest "claude-hm-enable-workflows-valid-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.enableWorkflows = true;
        };
      };
    in
      (result.config.programs.claude-code.settings.enableWorkflows or null) == true
  );

  # Valid workflowKeywordTriggerEnabled reaches upstream (typed nullOr bool);
  # `false` survives the null-filter (filterNulls drops null, keeps false).
  module-claude-hm-workflow-keyword-trigger-valid-reaches-upstream = mkTest "claude-hm-workflow-keyword-trigger-valid-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.workflowKeywordTriggerEnabled = false;
        };
      };
      s = result.config.programs.claude-code.settings or {};
    in
      (s ? workflowKeywordTriggerEnabled)
      && s.workflowKeywordTriggerEnabled == false
  );

  # Meta option: ultracodeOnLaunch = true writes both the undocumented
  # `ultracode` key and the `enableWorkflows` master toggle to upstream.
  module-claude-hm-ultracode-on-launch-writes-settings = mkTest "claude-hm-ultracode-on-launch-writes-settings" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          ultracodeOnLaunch = true;
        };
      };
      s = result.config.programs.claude-code.settings or {};
    in
      (s.ultracode or null) == true && (s.enableWorkflows or null) == true
  );

  # Meta option uses mkDefault, so an explicit settings.ultracode = false
  # wins over ultracodeOnLaunch, and the false survives the null-filter.
  module-claude-hm-ultracode-on-launch-explicit-false-wins = mkTest "claude-hm-ultracode-on-launch-explicit-false-wins" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          ultracodeOnLaunch = true;
          settings.ultracode = false;
        };
      };
      s = result.config.programs.claude-code.settings or {};
    in
      (s ? ultracode) && s.ultracode == false
  );

  # Negative invariant: ultracodeOnLaunch writes ONLY ultracode +
  # enableWorkflows. It must NOT set effortLevel (ultracode implies xhigh) or
  # workflowKeywordTriggerEnabled (orthogonal per-turn key). Guards against a
  # future fan-out accidentally over-reaching.
  module-claude-hm-ultracode-on-launch-omits-orthogonal-keys = mkTest "claude-hm-ultracode-on-launch-omits-orthogonal-keys" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          ultracodeOnLaunch = true;
        };
      };
      s = result.config.programs.claude-code.settings or {};
    in
      !(s ? effortLevel) && !(s ? workflowKeywordTriggerEnabled)
  );

  # Soft-enum model: an arbitrary (unknown) id is accepted and reaches upstream.
  module-claude-hm-model-soft-enum-accepts-arbitrary = mkTest "claude-hm-model-soft-enum-accepts-arbitrary" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.model = "some-future-model";
        };
      };
    in
      (result.config.programs.claude-code.settings.model or null) == "some-future-model"
  );

  module-claude-hm-writes-instruction-rule-file = mkTest "claude-hm-writes-instruction-rule-file" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.instructions = [
          {
            name = "my-rule";
            text = "Always use strict mode.";
            paths = ["src/**"];
          }
        ];
      };
      ruleFile = result.config.home.file.".claude/rules/my-rule.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Always use strict mode" (ruleFile.text or "")
  );

  module-claude-hm-delegates-skills-to-upstream = mkTest "claude-hm-delegates-skills-to-upstream" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
    in
      result.config.programs.claude-code.skills ? stack-fix
  );

  module-claude-devenv-delegates-claude-code = mkTest "claude-devenv-delegates-claude-code" (
    let
      result = evalDevenv {
        ai.claude.enable = true;
      };
    in
      result.config.claude.code.enable or false
  );

  # Devenv: cfg.settings gap write — non-hook/non-mcpServers keys land
  # in files.".claude/settings.json".json. Module-system attrs merge with
  # upstream's hook write (not exercised here; upstream claude.code is
  # stubbed to `attrsOf anything`) produces a single settings.json on
  # disk in production.
  module-claude-devenv-settings-gap-writes-effort-level = mkTest "claude-devenv-settings-gap-writes-effort-level" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.effortLevel = "medium";
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.effortLevel or null) == "medium"
  );

  # Devenv: `env` flows through the gap write (no longer short-circuited
  # to a non-existent claude.code.env option).
  module-claude-devenv-settings-gap-writes-env = mkTest "claude-devenv-settings-gap-writes-env" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.env.FOO = "bar";
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.env.FOO or null) == "bar"
  );

  # Devenv: typed enableWorkflows flows through the gap write into
  # files.".claude/settings.json".json (parity with the HM typed key).
  module-claude-devenv-settings-gap-writes-enable-workflows = mkTest "claude-devenv-settings-gap-writes-enable-workflows" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.enableWorkflows = true;
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.enableWorkflows or null) == true
  );

  # Devenv: attribution `false` flows through the gap write as "" into
  # files.".claude/settings.json".json.attribution (parity with HM).
  module-claude-devenv-settings-gap-writes-attribution = mkTest "claude-devenv-settings-gap-writes-attribution" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.attribution.commit = false;
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.attribution.commit or null) == ""
  );

  # Devenv: ultracodeOnLaunch = true writes both ultracode and
  # enableWorkflows into the gap-written settings.json (parity with HM).
  module-claude-devenv-ultracode-on-launch-writes-settings = mkTest "claude-devenv-ultracode-on-launch-writes-settings" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          ultracodeOnLaunch = true;
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.ultracode or null) == true
      && (settingsFile.json.enableWorkflows or null) == true
  );

  # Devenv parity for the mkDefault override: an explicit settings.ultracode =
  # false wins over ultracodeOnLaunch and survives the gap-write null-filter.
  module-claude-devenv-ultracode-on-launch-explicit-false-wins = mkTest "claude-devenv-ultracode-on-launch-explicit-false-wins" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          ultracodeOnLaunch = true;
          settings.ultracode = false;
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json ? ultracode)
      && settingsFile.json.ultracode == false
  );

  # Devenv: the legacy `settings.hooks` escape hatch lowers verbatim into
  # files.".claude/settings.json".json.hooks — NOT claude.code.hooks anymore
  # (approach B). Composes with the typed event map via the formats.json merge.
  module-claude-devenv-settings-hooks-escape-hatch = mkTest "claude-devenv-settings-hooks-escape-hatch" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.hooks.PreToolUse = [{matcher = "Bash";}];
        };
      };
      settingsHooks = ((result.config.files.".claude/settings.json" or {}).json or {}).hooks or {};
      upstreamHooks = result.config.claude.code.hooks or {};
    in
      ((builtins.head (settingsHooks.PreToolUse or [])).matcher or null)
      == "Bash"
      && !(upstreamHooks ? PreToolUse)
  );

  # Devenv: empty ai.claude.settings produces no gap file (lib.mkIf
  # gate on hasGapSettings).
  module-claude-devenv-settings-empty-no-gap-file = mkTest "claude-devenv-settings-empty-no-gap-file" (
    let
      result = evalDevenv {
        ai.claude.enable = true;
      };
    in
      !(result.config.files ? ".claude/settings.json")
  );

  # Devenv: typed ai.claude.mcpServers entries are RENDERED before they
  # reach upstream `claude.code.mcpServers` (parity with the HM branch).
  # Upstream's devenv server submodule has no `package` option, so a raw
  # typed entry fails its strict type in a real devenv eval ("The option
  # 'claude.code.mcpServers.<name>.package' does not exist") — the stub
  # here is `attrsOf anything`, so the load-bearing assertion is that the
  # rendered shape carries NO raw `package` key and the derived
  # command/args. Uses a real server name (context7-mcp) so renderServer's
  # package branch (loadServer + mode-string args) is exercised end-to-end.
  module-claude-devenv-mcp-servers-rendered = mkTest "claude-devenv-mcp-servers-rendered" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          mcpServers.context7-mcp.package = pkgs.hello;
        };
      };
      rendered = (result.config.claude.code.mcpServers or {})."context7-mcp" or null;
    in
      rendered
      != null
      && !(rendered ? package)
      && rendered.type == "stdio"
      && lib.hasSuffix "/bin/hello" rendered.command
      && lib.take 2 rendered.args == ["--transport" "stdio"]
  );

  # Devenv/HM parity: the SAME typed config yields the SAME rendered
  # server attrset on both backends (programs.claude-code.mcpServers vs
  # claude.code.mcpServers) — the render is shared (lib.ai.renderServer),
  # so any divergence is a factory regression. `==` is decidable over
  # context-carrying strings (store paths in command/env).
  module-claude-devenv-mcp-servers-hm-parity = mkTest "claude-devenv-mcp-servers-hm-parity" (
    let
      cfg = {
        ai.claude = {
          enable = true;
          mcpServers.context7-mcp.package = pkgs.hello;
        };
      };
      hmServers = (evalHm cfg).config.programs.claude-code.mcpServers or {};
      dvServers = (evalDevenv cfg).config.claude.code.mcpServers or {};
    in
      hmServers
      != {}
      && hmServers == dvServers
  );

  module-claude-hm-sets-lsp-env-when-servers-present = mkTest "claude-hm-sets-lsp-env-when-servers-present" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      (result.config.programs.claude-code.settings.env.ENABLE_LSP_TOOL or null) == "1"
  );

  # ── Task 5 (A4b): Claude launch-effort unpin reconciler ────────

  # Default reconciler: flags from the committed sidecar are merged into
  # ~/.claude.json through the shared helper.
  module-claude-hm-reconciles-unpin-launch-effort = mkTest "claude-hm-reconciles-unpin-launch-effort" (
    let
      result = evalHm {ai.claude.enable = true;};
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation
      != null
      && lib.hasInfix "unpinOpus48LaunchEffort" (activation.text or "")
      && lib.hasInfix ".claude.json" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  # Emptied flag map: merge body omitted, but the applied-0 log still fires.
  module-claude-hm-unpin-empty-logs-zero = mkTest "claude-hm-unpin-empty-logs-zero" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.claude.unpinLaunchEffort = lib.mkForce {};
      };
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation
      != null
      && lib.hasInfix "reconciling 0" (activation.text or "")
      && !(lib.hasInfix "unpinOpus48LaunchEffort" (activation.text or ""))
  );

  # A key set false is still written (re-pins that model deliberately).
  module-claude-hm-unpin-false-key-written = mkTest "claude-hm-unpin-false-key-written" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.claude.unpinLaunchEffort.unpinOpus48LaunchEffort = false;
      };
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation != null && lib.hasInfix "false" (activation.text or "")
  );

  # ── Task 4 (A3): Copilot HM/devenv fanout absorption ──────────
  module-copilot-hm-wraps-package = mkTest "copilot-hm-wraps-package" (
    let
      result = evalHm {
        ai.copilot.enable = true;
      };
      packages = result.config.home.packages or [];
    in
      builtins.length packages >= 1
  );

  module-copilot-hm-writes-settings-json-activation = mkTest "copilot-hm-writes-settings-json-activation" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.copilot.settings.model = "gpt-4";
      };
      activation = result.config.home.activation.copilotSettingsMerge or null;
    in
      activation
      != null
      && lib.hasInfix "gpt-4" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  module-copilot-hm-writes-mcp-config-json = mkTest "copilot-hm-writes-mcp-config-json" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      mcpFile = result.config.home.file.".copilot/mcp-config.json" or null;
    in
      mcpFile
      != null
      && lib.hasInfix "test-server" (mcpFile.text or "")
  );

  module-copilot-hm-writes-instruction-files = mkTest "copilot-hm-writes-instruction-files" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.instructions = [
          {
            name = "my-rule";
            text = "Be concise.";
            paths = ["src/**"];
          }
        ];
      };
      instrFile = result.config.home.file.".github/instructions/my-rule.instructions.md" or null;
    in
      instrFile
      != null
      && lib.hasInfix "Be concise" (instrFile.text or "")
  );

  module-copilot-hm-writes-skills = mkTest "copilot-hm-writes-skills" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
      skillEntry = result.config.home.file.".copilot/skills/stack-fix" or null;
    in
      skillEntry != null
  );

  module-copilot-devenv-writes-mcp-config = mkTest "copilot-devenv-writes-mcp-config" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      result.config.files ? ".config/github-copilot/mcp-config.json"
  );

  # ── Task 4b: Copilot feature-gap closure ───────────────────────
  # lspServers → lsp-config.json (HM and devenv).
  module-copilot-hm-writes-lsp-config-json = mkTest "copilot-hm-writes-lsp-config-json" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
          };
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  module-copilot-devenv-writes-lsp-config-json = mkTest "copilot-devenv-writes-lsp-config-json" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
          };
        };
      };
      lspFile = result.config.files.".config/github-copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # environmentVariables → devenv env blob (native) and HM wrapper.
  module-copilot-devenv-env-blob-populated = mkTest "copilot-devenv-env-blob-populated" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
        };
      };
    in
      (result.config.env.COPILOT_MODEL or null) == "claude-sonnet-4"
  );

  # HM wrapper injects --additional-mcp-config flag when MCP servers
  # are present. We assert that home.packages contains exactly one
  # entry (the wrapped derivation) and that it carries the expected
  # name — the stub can't introspect postBuild content, but a named
  # symlinkJoin is a strong signal the wrapper fired.
  module-copilot-hm-wrapper-injects-mcp-config-flag = mkTest "copilot-hm-wrapper-injects-mcp-config-flag" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  module-copilot-hm-wrapper-exports-env-vars = mkTest "copilot-hm-wrapper-exports-env-vars" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  # No wrapper when there's nothing to wrap (no env vars, no MCP
  # servers) — we should get the raw package through.
  module-copilot-hm-no-wrapper-when-nothing-to-wrap = mkTest "copilot-hm-no-wrapper-when-nothing-to-wrap" (
    let
      result = evalHm {
        ai.copilot.enable = true;
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") != "copilot-cli-wrapped"
  );

  # agents → per-file writes under configDir.
  module-copilot-hm-writes-agent-files = mkTest "copilot-hm-writes-agent-files" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          agents.reviewer = "# Reviewer\n\nReview code carefully.";
        };
      };
      agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Review code carefully" (agentFile.text or "")
  );

  module-copilot-devenv-writes-agent-files = mkTest "copilot-devenv-writes-agent-files" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          agents.reviewer = "# Reviewer\n\nReview code carefully.";
        };
      };
      agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Review code carefully" (agentFile.text or "")
  );

  # Unnamed kiro instructions → a dedicated `.kiro/steering/instructions.md`
  # steering file. Kiro is directory-native, so context stays standalone in
  # AGENTS.md and the nameless remainder gets its own always-on file — the
  # malformed trailing-slash `.config/kiro/steering/` aggregate stray is gone.
  # (Formerly module-kiro-instructions-rendered, which asserted that stray.)
  module-kiro-unnamed-instructions-to-dedicated-file = mkTest "kiro-unnamed-instructions-to-dedicated-file" (
    let
      evaluated = evalHm {
        ai.kiro = {
          enable = true;
          instructions = [
            {
              text = "Kiro steering content.";
              description = "Kiro steering";
            }
          ];
        };
      };
      instrFile = evaluated.config.ai.kiro.steeringFiles."instructions.md" or null;
    in
      instrFile
      != null
      && lib.hasInfix "Kiro steering content." (instrFile.text or "")
      && !(lib.any (n: lib.hasInfix "/" n) (lib.attrNames evaluated.config.ai.kiro.steeringFiles))
  );

  # ── STAGE 3: kiro auto-memory wiring (lib/autoMemory.nix) ────
  # The generator produces reusable values for ai.kiro.hooks / ai.kiro.rules.
  # These assert the emitted v3 hook envelope + steering anchor and that HM and
  # devenv emit BYTE-IDENTICAL sources (B5 structural parity, no new module axis).

  # HM: the hook envelope reaches .kiro/hooks/kiro-memory.json with all three v3
  # lifecycle triggers and the per-role wrapper commands.
  module-kiro-auto-memory-hm-emits-hooks = mkTest "kiro-auto-memory-hm-emits-hooks" (
    let
      mem = kiroAutoMem {home = "/home/tester";};
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson = mem.hooks;
        };
      };
      hookText = (result.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix ''"version":"v1"'' hookText
      && lib.hasInfix ''"trigger":"Stop"'' hookText
      && lib.hasInfix ''"trigger":"SessionStart"'' hookText
      && lib.hasInfix ''"trigger":"Manual"'' hookText
      && lib.hasInfix ''"trigger":"UserPromptSubmit"'' hookText
      && lib.hasInfix ''"type":"command"'' hookText
      && lib.hasInfix "kiro-memory-stop" hookText
      && lib.hasInfix "kiro-memory-flush" hookText
      && lib.hasInfix "kiro-memory-manual" hookText
      && lib.hasInfix "kiro-memory-recall" hookText
  );

  # HM: the steering anchor reaches the kiro-auto-memory.md steering
  # entry with `inclusion: always` (paths = null) and the anchor body.
  module-kiro-auto-memory-hm-emits-steering = mkTest "kiro-auto-memory-hm-emits-steering" (
    let
      mem = kiroAutoMem {home = "/home/tester";};
      result = evalHm {
        ai.kiro = {
          enable = true;
          inherit (mem) rules;
        };
      };
      steerText = (result.config.ai.kiro.steeringFiles."kiro-auto-memory.md" or {}).text or "";
    in
      lib.hasInfix "inclusion: always" steerText
      && lib.hasInfix "Persistent project memory" steerText
  );

  # Parity (B5): HM and devenv emit the IDENTICAL hook JSON + steering file for
  # the same generator output — the whole point of riding the existing
  # ai.kiro.hooks / ai.kiro.rules fanout instead of adding a new module axis.
  module-kiro-auto-memory-hm-devenv-parity = mkTest "kiro-auto-memory-hm-devenv-parity" (
    let
      mem = kiroAutoMem {home = "/home/tester";};
      hm = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson = mem.hooks;
          inherit (mem) rules;
        };
      };
      dv = evalDevenv {
        ai.kiro = {
          enable = true;
          hooksJson = mem.hooks;
          inherit (mem) rules;
        };
      };
      hmHook = (hm.config.home.activation.kiroHooks or {}).text or "";
      # BOTH backends now install the hook as a REAL file (kiro v3 skips symlinked
      # hooks — verified live on 2.13.0): HM via home.activation, devenv via
      # enterShell. Parity is by construction (both emit `mem.hooks."kiro-memory"`):
      # assert each backend's script carries the generator output verbatim AND
      # installs it into .kiro/hooks/.
      dvEnter = dv.config.enterShell or "";
      # Steering is ALSO a real file now (the strategy-driven
      # materializer, copy default). Parity keeps BOTH layers: attrset
      # equality over steeringFiles (== is decidable over
      # context-carrying strings) AND one writer-output byte check per
      # backend via the heredoc-extraction idiom, so writer divergence
      # stays caught.
      hmSteerFiles = hm.config.ai.kiro.steeringFiles;
      dvSteerFiles = dv.config.ai.kiro.steeringFiles;
      hmSteer = (hmSteerFiles."kiro-auto-memory.md" or {}).text or "";
      # The heredoc re-appends exactly one trailing newline, so the
      # embedded body is the entry text minus that newline.
      expectedBody = matLib.stripTrailingNewline hmSteer;
      hmBody = matHeredocBody (hmWriteScript hm) "kiro-auto-memory.md";
      dvBody = matHeredocBody (dvTaskExec dv) "kiro-auto-memory.md";
    in
      hmHook
      != ""
      # `hasInfix` compiles the infix into a `builtins.match` regex, which rejects
      # a pattern carrying string context; the generator output embeds the wrapper
      # store paths, so strip context before matching (byte content is unchanged).
      && lib.hasInfix (builtins.unsafeDiscardStringContext mem.hooks."kiro-memory") hmHook
      && lib.hasInfix "kiro-memory.json" hmHook
      && lib.hasInfix ".kiro/hooks/kiro-memory.json" dvEnter
      && lib.hasInfix "install -m 0644" dvEnter
      # devenv enterShell runs in the caller's cwd (direnv activates in
      # subdirectories), so the relative hook write must be anchored to
      # the project root in a subshell.
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' dvEnter
      && hmSteer != ""
      && hmSteerFiles == dvSteerFiles
      && hmBody == expectedBody
      && dvBody == expectedBody
  );

  # HOME is baked into the wrappers: a different `home` (and the null fail-loud
  # branch) yields a different hook envelope via different wrapper store paths —
  # proving the S9/D25 HOME contract is load-bearing, not a no-op.
  module-kiro-auto-memory-home-baked = mkTest "kiro-auto-memory-home-baked" (
    let
      a = (kiroAutoMem {home = "/home/alice";}).hooks."kiro-memory";
      b = (kiroAutoMem {home = "/home/bob";}).hooks."kiro-memory";
      unset = (kiroAutoMem {home = null;}).hooks."kiro-memory";
      empty = (kiroAutoMem {home = "";}).hooks."kiro-memory";
    in
      a
      != b
      && a != unset
      && b != unset
      # Regression guard: an empty-string `home` must NOT bake `export HOME=''`
      # (silent cwd-relative memory-loss) — it takes the same guard-only path as
      # null, so its output is byte-identical to the null case.
      && empty == unset
  );

  # STAGE 5b backend wiring: the recall wrapper must (a) prepend the openmemory-mem
  # bin dir to PATH, (b) bake the non-secret omEnv, and (c) cat the password FILE at
  # runtime — never bake the secret into the store. The wrapper is a store path
  # referenced from the (context-carrying) hook JSON, so passing that JSON as a build
  # input realizes all four wrappers; then grep the recall one on disk.
  module-kiro-auto-memory-backend-wiring = let
    mem = kiroAutoMem {
      home = "/home/tester";
      omEnv = {
        OM_PG_HOST = "db.example";
        OM_USER_ID = "dev-no-auth";
      };
      omPgPasswordFile = "/run/secrets/om-pg";
    };
    # fromJSON rejects a context-carrying string, and the JSON holds the wrapper
    # store paths — so strip context to PARSE (safe: the path is only used as a grep
    # target; the wrappers are realized via hookFile's retained context below).
    envelope = builtins.fromJSON (builtins.unsafeDiscardStringContext mem.hooks."kiro-memory");
    cmdFor = trigger:
      (lib.findFirst (h: h.trigger == trigger)
        (throw "no ${trigger} hook")
        envelope.hooks).action.command;
    recallCmd = cmdFor "UserPromptSubmit";
    # The write-path wrappers (Stop/SessionStart/Manual) also shell to openmemory-mem
    # (`add`), so they must share the SAME PATH + secret wiring — grep one to catch a
    # future per-wrapper refactor that drops it from the write side (P8).
    stopCmd = cmdFor "Stop";
  in
    pkgs.runCommand "module-test-kiro-auto-memory-backend-wiring" {
      # writeText persists the context-carrying hook JSON (as real HM does), so its
      # build realizes all four wrapper store paths — then the cmd paths exist on disk.
      hookFile = pkgs.writeText "kiro-memory-hooks.json" mem.hooks."kiro-memory";
    } ''
      fail() {
        echo "FAIL: kiro-auto-memory-backend-wiring: $1" >&2
        exit 1
      }
      w=${recallCmd}
      grep -q 'export PATH=' "$w" || fail "recall: no PATH prepend"
      grep -q 'openmemory-mcp-stub' "$w" || fail "recall: openmemory-mem bin dir not on PATH"
      grep -q 'OM_PG_HOST=' "$w" || fail "recall: omEnv OM_PG_HOST not baked"
      grep -q 'OM_USER_ID=' "$w" || fail "recall: omEnv OM_USER_ID not baked"
      # Runtime form is `OM_PG_PASSWORD="$(cat …)"` (double-quote); a baked secret
      # would be single-quoted by escapeShellArg (`OM_PG_PASSWORD='…'`).
      grep -q 'OM_PG_PASSWORD="' "$w" || fail "recall: password not read at runtime"
      grep -q '/run/secrets/om-pg' "$w" || fail "recall: password file path missing"
      if grep -q "OM_PG_PASSWORD='" "$w"; then fail "recall: password baked into store"; fi
      # A write-path wrapper shares the wiring (openmemory-mem `add` + the same secret).
      s=${stopCmd}
      grep -q 'openmemory-mcp-stub' "$s" || fail "stop: openmemory-mem bin dir not on PATH"
      grep -q 'OM_PG_PASSWORD="' "$s" || fail "stop: password not read at runtime"
      if grep -q "OM_PG_PASSWORD='" "$s"; then fail "stop: password baked into store"; fi
      echo PASS > "$out"
    '';

  # D33: Manual `/remember` must FORCE an immediate distill — its wrapper bakes
  # KIRO_MEMORY_FORCE=1 (which distiller main() honors, bypassing the debounce),
  # while the per-turn Stop wrapper must stay debounced (no FORCE). Realize both
  # wrappers on disk and grep them — this locks the per-wrapper distinction so a
  # future refactor cannot collapse Manual back onto the debounced Stop path (the
  # STAGE-6-surfaced gap where /remember silently no-op'd after a recent Stop).
  module-kiro-auto-memory-manual-forces = let
    mem = kiroAutoMem {home = "/home/tester";};
    envelope = builtins.fromJSON (builtins.unsafeDiscardStringContext mem.hooks."kiro-memory");
    cmdFor = trigger:
      (lib.findFirst (h: h.trigger == trigger)
        (throw "no ${trigger} hook")
        envelope.hooks).action.command;
    manualCmd = cmdFor "Manual";
    stopCmd = cmdFor "Stop";
  in
    pkgs.runCommand "module-test-kiro-auto-memory-manual-forces" {
      hookFile = pkgs.writeText "kiro-memory-hooks.json" mem.hooks."kiro-memory";
    } ''
      fail() {
        echo "FAIL: kiro-auto-memory-manual-forces: $1" >&2
        exit 1
      }
      m=${manualCmd}
      grep -q 'export KIRO_MEMORY_FORCE=1' "$m" \
        || fail "manual: /remember must force an immediate distill (KIRO_MEMORY_FORCE=1 not baked)"
      s=${stopCmd}
      if grep -q 'KIRO_MEMORY_FORCE' "$s"; then
        fail "stop: per-turn Stop must stay debounced (KIRO_MEMORY_FORCE leaked into the stop wrapper)"
      fi
      echo PASS > "$out"
    '';

  # STAGE 5b: a secret smuggled via EITHER env or omEnv would bake into the world-
  # readable store (bakedEnv = env // omEnv), so the generator asserts against the
  # merged set — evaluation must FAIL (tryEval success=false) for both routes.
  module-kiro-auto-memory-rejects-baked-password = mkTest "kiro-auto-memory-rejects-baked-password" (
    let
      throws = args: !(builtins.tryEval (kiroAutoMem args).hooks."kiro-memory").success;
    in
      throws {
        home = "/home/tester";
        omEnv = {OM_PG_PASSWORD = "leak";};
      }
      && throws {
        home = "/home/tester";
        env = {OM_PG_PASSWORD = "leak";};
      }
  );

  # ── Task 5 (A4): Kiro HM/devenv fanout absorption ────────────

  # HM: package installation — verify home.packages populated.
  module-kiro-hm-wraps-package = mkTest "kiro-hm-wraps-package" (
    let
      result = evalHm {
        ai.kiro.enable = true;
      };
      packages = result.config.home.packages or [];
    in
      builtins.length packages >= 1
  );

  # HM: settings activation merge — verify activation script
  # contains jq merge and settings content.
  module-kiro-hm-writes-settings-activation = mkTest "kiro-hm-writes-settings-activation" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "claude-sonnet-4";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation
      != null
      && lib.hasInfix "claude-sonnet-4" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  # Known Kiro model id reaches the cli.json merge.
  module-kiro-hm-default-model-known-accepted = mkTest "kiro-hm-default-model-known-accepted" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "claude-opus-4.8";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation != null && lib.hasInfix "claude-opus-4.8" (activation.text or "")
  );

  # Arbitrary (unknown) id is accepted (str branch of the soft enum).
  module-kiro-hm-default-model-arbitrary-accepted = mkTest "kiro-hm-default-model-arbitrary-accepted" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "some-future-model";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation != null && lib.hasInfix "some-future-model" (activation.text or "")
  );

  # v3 = true triggers the HM wrapper (appends --v3 to the launcher).
  # Stub can't introspect postBuild, but a named symlinkJoin
  # ("kiro-cli-wrapped") is a strong signal the wrapper fired — same
  # fidelity as the copilot wrapper tests.
  module-kiro-hm-v3-wraps-package = mkTest "kiro-hm-v3-wraps-package" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          v3 = true;
        };
      };
      packages = result.config.home.packages or [];
    in
      lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages
  );

  # tui = true implies --v3 at the launcher (bare --tui is rejected on
  # 2.8.1), so it must wrap. hasV3 = v3 || tui.
  module-kiro-hm-tui-implies-v3-wraps = mkTest "kiro-hm-tui-implies-v3-wraps" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          tui = true;
        };
      };
      packages = result.config.home.packages or [];
    in
      lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages
  );

  # devenv parity: v3 = true must wrap on devenv too, so `devenv shell` launches
  # the v3 engine like HM does (was HM-only before the shared wrapper). devenv
  # exports env natively, so the wrapper carries flags only — but the symlinkJoin
  # ("kiro-cli-wrapped") still fires on v3/tui alone.
  module-kiro-devenv-v3-wraps-package = mkTest "kiro-devenv-v3-wraps-package" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          v3 = true;
        };
      };
      packages = result.config.packages or [];
    in
      lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages
  );

  # devenv parity: tui implies --v3, so it must wrap on devenv too.
  module-kiro-devenv-tui-implies-v3-wraps = mkTest "kiro-devenv-tui-implies-v3-wraps" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          tui = true;
        };
      };
      packages = result.config.packages or [];
    in
      lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages
  );

  # devenv: with no tui/v3/trust and no env, the package is installed RAW (the
  # shared wrapper returns the unwrapped derivation — no needless symlinkJoin).
  module-kiro-devenv-no-flags-no-wrap = mkTest "kiro-devenv-no-flags-no-wrap" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
      };
      packages = result.config.packages or [];
    in
      !(lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages)
  );

  # HM: mcp.json — verify mergedServers writes mcp config.
  module-kiro-hm-writes-mcp-json = mkTest "kiro-hm-writes-mcp-json" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      mcpFile = result.config.home.file.".kiro/settings/mcp.json" or null;
    in
      mcpFile
      != null
      && lib.hasInfix "test-server" (mcpFile.text or "")
  );

  # HM: lsp.json — verify LSP server config write.
  module-kiro-hm-writes-lsp-json = mkTest "kiro-hm-writes-lsp-json" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          lspServers.nix = {
            command = "nixd";
            args = [];
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # HM: explicit `permissions` rules render permissions.yaml (source is a
  # pkgs.formats.yaml derivation, so we assert the file ENTRY exists).
  module-kiro-hm-permissions-explicit-rendered = mkTest "kiro-hm-permissions-explicit-rendered" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          permissions = [
            {
              capability = "mcp";
              effect = "allow";
              match = ["openmemory/*"];
            }
          ];
        };
      };
    in
      (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
  );

  # HM: under v3 (tui implies v3), `trustedMcpTools` is translated into
  # permissions.yaml — so the file is written even with no explicit rules.
  module-kiro-hm-permissions-translated-under-v3 = mkTest "kiro-hm-permissions-translated-under-v3" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          tui = true;
          trustedMcpTools = ["@openmemory" "@git-mcp/git_diff" "subagent" "use_aws"];
        };
      };
    in
      (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
  );

  # HM: without v3 (no tui, no v3) and no explicit permissions, the
  # trustedMcpTools list is NOT translated — no permissions.yaml written.
  module-kiro-hm-permissions-absent-without-v3 = mkTest "kiro-hm-permissions-absent-without-v3" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          trustedMcpTools = ["@openmemory"];
        };
      };
    in
      (result.config.home.file.".kiro/settings/permissions.yaml" or null) == null
  );

  # HM: per-instruction steering entries with kiro transformer frontmatter.
  # Verifies the kiro transformer emits `inclusion:` and `name:` fields.
  module-kiro-hm-writes-steering-files = mkTest "kiro-hm-writes-steering-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          instructions = [
            {
              name = "my-steering";
              text = "Use strict mode always.";
              paths = ["src/**" "tests/**"];
            }
          ];
        };
      };
      steeringFile = result.config.ai.kiro.steeringFiles."my-steering.md" or null;
    in
      steeringFile
      != null
      && lib.hasInfix "Use strict mode always" (steeringFile.text or "")
      && lib.hasInfix "inclusion: fileMatch" (steeringFile.text or "")
      && lib.hasInfix "name: my-steering" (steeringFile.text or "")
      # CRITICAL: fileMatchPattern MUST be a YAML array for multi-element
      # paths, not a comma-joined string.
      && lib.hasInfix "fileMatchPattern: [" (steeringFile.text or "")
  );

  # HM: per-CLI context → the `<contextFilename>` steering entry
  # (default AGENTS.md), delivered by the copy writer — the legacy
  # home.file symlink must be GONE under the default copy strategy.
  module-kiro-hm-writes-context = mkTest "kiro-hm-writes-context" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Project conventions go here.";
        };
      };
      contextFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Project conventions" (contextFile.text or "")
      && !(result.config.home.file ? ".kiro/steering/AGENTS.md")
      && lib.hasInfix "AGENTS.md" (hmWriteScript result)
  );

  # HM: top-level ai.context fans out to kiro when per-CLI unset.
  module-kiro-hm-top-level-context-fallback = mkTest "kiro-hm-top-level-context-fallback" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # HM: per-CLI context wins over top-level when both set.
  module-kiro-hm-per-cli-context-precedence = mkTest "kiro-hm-per-cli-context-precedence" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Per-CLI wins.";
        };
        ai.context = "Top-level loses.";
      };
      contextFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Per-CLI wins" (contextFile.text or "")
      && !(lib.hasInfix "Top-level loses" (contextFile.text or ""))
  );

  # HM: contextFilename override redirects the context emission.
  module-kiro-hm-context-filename-override = mkTest "kiro-hm-context-filename-override" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Custom filename.";
          contextFilename = "custom.md";
        };
      };
      customFile = result.config.ai.kiro.steeringFiles."custom.md" or null;
      agentsFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      customFile != null && agentsFile == null
  );

  # HM: skills fanout via mkSkillEntries.
  module-kiro-hm-writes-skills = mkTest "kiro-hm-writes-skills" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
      skillEntry = result.config.home.file.".kiro/skills/stack-fix" or null;
    in
      skillEntry != null
  );

  # HM: wrapper injects env vars. When env vars are set, the
  # installed package should be the wrapped derivation.
  module-kiro-hm-wrapper-exports-env-vars = mkTest "kiro-hm-wrapper-exports-env-vars" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          environmentVariables.KIRO_LOG_LEVEL = "debug";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "kiro-cli-wrapped"
  );

  # HM: no wrapper when nothing to wrap.
  module-kiro-hm-no-wrapper-when-nothing-to-wrap = mkTest "kiro-hm-no-wrapper-when-nothing-to-wrap" (
    let
      result = evalHm {
        ai.kiro.enable = true;
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") != "kiro-cli-wrapped"
  );

  # HM: agent JSON files written under configDir/agents/.
  module-kiro-hm-writes-agent-files = mkTest "kiro-hm-writes-agent-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          agents.reviewer = ''{"role": "reviewer"}'';
        };
      };
      agentFile = result.config.home.file.".kiro/agents/reviewer.json" or null;
    in
      agentFile != null
  );

  # HM: hook JSON files written under configDir/hooks/.
  module-kiro-hm-writes-hook-files = mkTest "kiro-hm-writes-hook-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson.pre-commit = ''{"event": "pre-commit"}'';
        };
      };
      hookScript = (result.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix "pre-commit.json" hookScript
      && lib.hasInfix ''"event": "pre-commit"'' hookScript
  );

  # HM: a TYPED hook record lowers to the correct v3 envelope JSON. name = attr
  # key; null optionals dropped; action nulls dropped.
  module-kiro-hooks-typed-hm-emits-envelope = mkTest "kiro-hooks-typed-hm-emits-envelope" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooks.lint = {
            trigger = "PostToolUse";
            matcher = "fs_write";
            action.command = "just lint";
            timeout = 30;
          };
        };
      };
      t = (result.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix ''"version":"v1"'' t
      && lib.hasInfix ''"name":"lint"'' t
      && lib.hasInfix ''"trigger":"PostToolUse"'' t
      && lib.hasInfix ''"matcher":"fs_write"'' t
      && lib.hasInfix ''"type":"command"'' t
      && lib.hasInfix ''"command":"just lint"'' t
      && lib.hasInfix ''"timeout":30'' t
      # `enabled`/`description` were null → omitted.
      && !(lib.hasInfix ''"enabled"'' t)
      && !(lib.hasInfix ''"description"'' t)
  );

  # HM: S1 — an `action.command` package coerces to its getExe store path so
  # companion files ride the closure at an absolute, cwd-independent path.
  module-kiro-hooks-command-accepts-package = mkTest "kiro-hooks-command-accepts-package" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooks.fmt = {
            trigger = "PostToolUse";
            action.command = pkgs.hello;
          };
        };
      };
      t = (result.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix ''"command":"/nix/store'' t && lib.hasInfix "/bin/hello" t
  );

  # HM↔devenv: the same typed hook emits the envelope on HM (home.file text) and
  # devenv installs the REAL file via enterShell (v3 skips symlinked hooks).
  module-kiro-hooks-typed-devenv-installs = mkTest "kiro-hooks-typed-devenv-installs" (
    let
      cfg = {
        ai.kiro = {
          enable = true;
          hooks.lint = {
            trigger = "PostToolUse";
            action.command = "just lint";
          };
        };
      };
      hmT = ((evalHm cfg).config.home.activation.kiroHooks or {}).text or "";
      dvEnter = (evalDevenv cfg).config.enterShell or "";
    in
      lib.hasInfix ''"trigger":"PostToolUse"'' hmT
      && lib.hasInfix ".kiro/hooks/lint.json" dvEnter
      && lib.hasInfix "install -m 0644" dvEnter
      # relative hook write anchored to the project root (enterShell runs
      # in the caller's cwd).
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' dvEnter
  );

  # HM+devenv: records sharing a `file` co-locate into ONE envelope (N hooks in
  # one file — the typed path off the raw `hooksJson` escape hatch, e.g.
  # autoMemory's set in kiro-memory.json). A record without `file` keeps its own
  # <name>.json (back-compat); the Nix-only `file` key is stripped from output.
  # PR #433 moved HM hook delivery to home.activation real files (kiro v3 skips
  # store symlinks), so each envelope is read back out of its activation-script
  # heredoc body and structurally asserted via fromJSON — same strength as the
  # old home.file text read.
  module-kiro-hooks-typed-colocation = mkTest "kiro-hooks-typed-colocation" (
    let
      cfg = {
        ai.kiro = {
          enable = true;
          hooks = {
            mem-stop = {
              file = "kiro-memory";
              trigger = "Stop";
              action.command = "/bin/stop";
            };
            mem-recall = {
              file = "kiro-memory";
              trigger = "UserPromptSubmit";
              action.command = "/bin/recall";
            };
            solo = {
              trigger = "PostToolUse";
              matcher = "fs_write";
              action.command = "/bin/solo";
            };
          };
        };
      };
      # The activation script embeds coreutils store paths, and every substring
      # inherits the whole string's context — which fromJSON rejects. Strip it
      # (same idiom as the auto-memory parity test); byte content is unchanged.
      hmT =
        builtins.unsafeDiscardStringContext
        (((evalHm cfg).config.home.activation.kiroHooks or {}).text or "");
      # Exact heredoc body for one emitted hook file: the script writes
      # `cat > "$HOOKS_DIR/<file>.json" <<'NAT_KIRO_HOOK_EOF'` + body + EOF.
      hookBody = file: let
        parts = lib.splitString "\"$HOOKS_DIR/${file}.json\" <<'NAT_KIRO_HOOK_EOF'\n" hmT;
      in
        if builtins.length parts < 2
        then ""
        else builtins.head (lib.splitString "\nNAT_KIRO_HOOK_EOF" (builtins.elemAt parts 1));
      coText = hookBody "kiro-memory";
      co = builtins.fromJSON coText;
      soloText = hookBody "solo";
      dvEnter = (evalDevenv cfg).config.enterShell or "";
    in
      # both co-located records land in ONE kiro-memory.json envelope
      co.version
      == "v1"
      && builtins.length co.hooks == 2
      && lib.any (h: h.name == "mem-stop" && h.trigger == "Stop") co.hooks
      && lib.any (h: h.name == "mem-recall" && h.trigger == "UserPromptSubmit") co.hooks
      # the Nix-only `file` grouping key is stripped from every emitted hook object
      && !(lib.any (h: h ? file) co.hooks)
      && !(lib.hasInfix ''"file"'' coText)
      # a record without `file` keeps its own <name>.json (back-compat)
      && lib.hasInfix ''"name":"solo"'' soloText
      # the co-located records do NOT also emit their own per-record files
      && !(lib.hasInfix "mem-stop.json" hmT)
      && !(lib.hasInfix "mem-recall.json" hmT)
      # devenv installs the SAME grouped file (parity) and NOT per-record files
      && lib.hasInfix ".kiro/hooks/kiro-memory.json" dvEnter
      && !(lib.hasInfix "mem-stop.json" dvEnter)
  );

  # A PATH-valued hooksJson entry must emit the file CONTENT, not the path string
  # (mkAllHookFiles resolves paths so devenv's writeText writes the body too).
  module-kiro-hooks-json-path-resolves = mkTest "kiro-hooks-json-path-resolves" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson.raw = ./fixtures/kiro-hook-raw.json;
        };
      };
      t = (result.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix "raw-envelope-loaded" t
  );

  # Hardening (PR #433 review): an unsafe hook name (path separator) fails the
  # name-charset assertion before it can be interpolated into a hooks-dir path.
  module-kiro-hooks-rejects-unsafe-name = mkTest "kiro-hooks-rejects-unsafe-name" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson."../evil" = builtins.toJSON {
            version = "v1";
            hooks = [];
          };
        };
      };
      nameAsserts =
        builtins.filter (a: lib.hasInfix "hook names must match" a.message)
        (ev.config.assertions or []);
    in
      nameAsserts != [] && (builtins.head nameAsserts).assertion == false
  );

  # A safe hook name passes the same assertion (assertion == true).
  module-kiro-hooks-accepts-safe-name = mkTest "kiro-hooks-accepts-safe-name" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson."kiro-memory.pre_1" = builtins.toJSON {
            version = "v1";
            hooks = [];
          };
        };
      };
      nameAsserts =
        builtins.filter (a: lib.hasInfix "hook names must match" a.message)
        (ev.config.assertions or []);
    in
      nameAsserts != [] && (builtins.head nameAsserts).assertion == true
  );

  # Hardening (PR #433 review): the HM hook activation prunes stale *.json first,
  # so a hook removed/renamed in config stops firing.
  module-kiro-hooks-hm-prunes-stale = mkTest "kiro-hooks-hm-prunes-stale" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          hooksJson.demo = builtins.toJSON {
            version = "v1";
            hooks = [];
          };
        };
      };
      script = (ev.config.home.activation.kiroHooks or {}).text or "";
    in
      lib.hasInfix ''for f in "$HOOKS_DIR"/*.json'' script
      && lib.hasInfix "rm -f" script
      && lib.hasInfix "set -euETo pipefail" script
  );

  # Devenv: mcp.json write.
  module-kiro-devenv-writes-mcp-json = mkTest "kiro-devenv-writes-mcp-json" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      result.config.files ? ".kiro/settings/mcp.json"
  );

  # Devenv: lsp.json write.
  module-kiro-devenv-writes-lsp-json = mkTest "kiro-devenv-writes-lsp-json" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          lspServers.nix = {
            command = "nixd";
            args = [];
          };
        };
      };
      lspFile = result.config.files.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # Devenv: environment variables populate the env blob.
  module-kiro-devenv-env-blob-populated = mkTest "kiro-devenv-env-blob-populated" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          environmentVariables.KIRO_LOG_LEVEL = "debug";
        };
      };
    in
      (result.config.env.KIRO_LOG_LEVEL or null) == "debug"
  );

  # Devenv: settings/cli.json static write.
  module-kiro-devenv-writes-settings-json = mkTest "kiro-devenv-writes-settings-json" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          settings.telemetry.enabled = false;
        };
      };
      settingsFile = result.config.files.".kiro/settings/cli.json" or null;
    in
      settingsFile
      != null
      && lib.hasInfix "telemetry" (settingsFile.text or "")
  );

  # Devenv: per-CLI context → the `<contextFilename>` steering entry
  # (parity with HM), delivered by the materialize task — the legacy
  # files.* symlink must be GONE under the default copy strategy.
  module-kiro-devenv-writes-context = mkTest "kiro-devenv-writes-context" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          context = "Project conventions go here.";
        };
      };
      contextFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Project conventions" (contextFile.text or "")
      && !(result.config.files ? ".kiro/steering/AGENTS.md")
      && lib.hasInfix "AGENTS.md" (dvTaskExec result)
  );

  # Devenv: top-level ai.context fans to kiro when per-CLI unset.
  module-kiro-devenv-top-level-context-fallback = mkTest "kiro-devenv-top-level-context-fallback" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile = result.config.ai.kiro.steeringFiles."AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # Devenv: agent files written.
  module-kiro-devenv-writes-agent-files = mkTest "kiro-devenv-writes-agent-files" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          agents.reviewer = ''{"role": "reviewer"}'';
        };
      };
      agentFile = result.config.files.".kiro/agents/reviewer.json" or null;
    in
      agentFile
      != null
      && lib.hasInfix "reviewer" (agentFile.text or "")
  );

  # Devenv: hook files written as REAL files via enterShell (kiro v3 does not
  # discover symlinked hooks, so devenv `files.*` symlinks are wrong here — the
  # enterShell copies the content into a plain `.kiro/hooks/<name>.json`).
  module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          hooksJson.pre-commit = ''{"event": "pre-commit"}'';
        };
      };
      enter = result.config.enterShell or "";
    in
      lib.hasInfix ".kiro/hooks/pre-commit.json" enter
      && lib.hasInfix "install -m 0644" enter
      # relative hook write anchored to the project root (enterShell runs
      # in the caller's cwd — direnv activates in subdirectories).
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' enter
      # not a devenv `files.*` symlink
      && !((result.config.files or {}) ? ".kiro/hooks/pre-commit.json")
  );

  # Devenv: the external `hooksDir` fragment copies the directory contents
  # into `.kiro/hooks/` as real files via enterShell — same v3-symlink
  # rationale as the inline fragment above, and the same project-root
  # anchoring (the relative destination would otherwise land in whatever
  # subdirectory the shell was entered from).
  module-kiro-devenv-hooks-dir-copies-anchored = mkTest "kiro-devenv-hooks-dir-copies-anchored" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          hooksDir = ./fixtures/kiro-hooks-dir;
        };
      };
      enter = result.config.enterShell or "";
    in
      lib.hasInfix ''cd "$DEVENV_ROOT"'' enter
      && lib.hasInfix "cp -rL --no-preserve=mode" enter
      && lib.hasInfix "kiro-hooks-dir/." enter
      && lib.hasInfix ".kiro/hooks/" enter
      # real-file copy, not devenv `files.*` symlinks
      && !(lib.any (n: lib.hasPrefix ".kiro/hooks/" n) (lib.attrNames (result.config.files or {})))
  );

  # ── Steering materializer (strategy-driven) ────────────────────────
  # lib/ai/materialize.nix + the ai.kiro.steeringFiles derived attrset.
  # Known gap (recorded): the dag stub discards before/after, so the
  # entryBefore ["checkLinkTargets"] / entryAfter ["linkGeneration"]
  # ordering cannot be asserted here — an nmt-based check (P4) covers
  # it.

  # [B1] Two emitters producing the SAME steering key with DIFFERENT
  # content must be a hard eval error (steeringFiles.<n>.text is
  # nullOr str → conflicting definition values). A rule named "AGENTS"
  # and the default contextFilename both land on "AGENTS.md" with
  # different bodies — this exact pair silently CONCATENATED under the
  # old home.file `lines` merge.
  module-kiro-steering-collision-errors = mkTest "kiro-steering-collision-errors" (
    let
      attempt = builtins.tryEval (
        let
          ev = evalHm {
            ai.kiro = {
              enable = true;
              context = "CONTEXT-COLLIDER.";
              rules.AGENTS.text = "RULE-COLLIDER.";
            };
          };
        in
          builtins.seq ev.config.ai.kiro.steeringFiles."AGENTS.md".text true
      );
    in
      !attempt.success
  );

  # [B6-partial] The copy writers exist whenever the module is enabled —
  # even with an EMPTY steering set — so emptying the surface still
  # prunes previously materialized files (N→0). Both backends.
  module-kiro-steering-empty-set-still-prunes = mkTest "kiro-steering-empty-set-still-prunes" (
    let
      hm = evalHm {ai.kiro.enable = true;};
      prune = hmPruneScript hm;
      write = hmWriteScript hm;
      dv = evalDevenv {ai.kiro.enable = true;};
      task = (dv.config.tasks or {})."ai:kiro:materialize-steering" or null;
    in
      hm.config.ai.kiro.steeringFiles
      == {}
      # prune pass present (walks the previous manifest and removes)…
      && lib.hasInfix "$NAT_MAT_MANIFEST" prune
      && lib.hasInfix "rm -f" prune
      # …and the write phase still rewrites the manifest (to empty)
      && lib.hasInfix "NAT_MAT_NEW_MANIFEST" write
      && task != null
      && lib.hasInfix "$NAT_MAT_MANIFEST" (task.exec or "")
  );

  # [B7] devenv copy entries ship an enterTest backstop asserting each
  # target is a REAL file (not a symlink) — a failed materialize task
  # only warns at shell entry; the fragment makes `devenv test`/CI
  # fail. Ships WITH the module to every consumer.
  module-kiro-steering-devenv-enter-test = mkTest "kiro-steering-devenv-enter-test" (
    let
      dv = evalDevenv {
        ai.kiro = {
          enable = true;
          context = "ENTER-TEST-TOKEN.";
        };
      };
      et = dv.config.enterTest or "";
    in
      lib.hasInfix ".kiro/steering/AGENTS.md" et
      && lib.hasInfix "[ -L" et
      && lib.hasInfix "not materialized as a real file" et
  );

  # [B4] devenv task ordering edges: cleanup-first is unconditional; the
  # devenv:files edge exists ONLY when files.* entries exist — an
  # unconditional edge would TasksNotFound on all-copy consumers, the
  # design's own end-state (review follow-up: this regression previously
  # passed the whole suite).
  module-kiro-steering-task-edges = mkTest "kiro-steering-task-edges" (
    let
      bare = evalDevenv {ai.kiro.enable = true;};
      bareTask = (bare.config.tasks or {})."ai:kiro:materialize-steering" or {};
      withFiles = evalDevenv {
        ai.kiro.enable = true;
        files."probe.txt".text = "probe";
      };
      filesTask = (withFiles.config.tasks or {})."ai:kiro:materialize-steering" or {};
    in
      (bareTask.after or [])
      == ["devenv:files:cleanup"]
      && lib.elem "devenv:enterShell" (bareTask.before or [])
      && !(lib.elem "devenv:files" (bareTask.before or []))
      && lib.elem "devenv:files" (filesTask.before or [])
  );

  # `steeringStrategy = "symlink"` escape hatch: restores exactly the
  # legacy declarative shapes on both backends, and the copy writer
  # carries no entry for the symlinked name.
  module-kiro-steering-symlink-strategy = mkTest "kiro-steering-symlink-strategy" (
    let
      cfg = {
        ai.kiro = {
          enable = true;
          steeringStrategy = "symlink";
          context = "SYMLINK-CTX-TOKEN.";
        };
      };
      hm = evalHm cfg;
      dv = evalDevenv cfg;
      hmEntry = hm.config.home.file.".kiro/steering/AGENTS.md" or null;
      dvEntry = dv.config.files.".kiro/steering/AGENTS.md" or null;
    in
      hmEntry
      != null
      && lib.hasInfix "SYMLINK-CTX-TOKEN." (hmEntry.text or "")
      && dvEntry != null
      && (hm.config.ai.kiro.steeringFiles."AGENTS.md" or {}).strategy or null == "symlink"
      && !(lib.hasInfix "AGENTS.md" (hmWriteScript hm))
      && !(lib.hasInfix "AGENTS.md" (dvTaskExec dv))
  );

  # ── Stacked-workflows: skills + router, user-global (HM) + project (devenv) ──
  # Scope-revert (docs/plans/stacked-workflows-scope-revert-plan.md): the HM
  # module now installs the (unprefixed) stack-* skills + routing table
  # user-global; the devenv module mirrors them project-local. References are
  # bundled as REAL files inside each skill dir (deref'd at build).

  # Default disabled — stacked-workflows.enable defaults to false.
  module-sws-default-disabled = mkTest "sws-default-disabled" (
    let
      result = evalHm {};
    in
      !(result.config.stacked-workflows.enable or true)
  );

  # Devenv scope: enable -> ai.skills gets the unprefixed stack-* skills
  # (each enabled CLI fans them out at project-local scope).
  module-sws-devenv-enable-sets-ai-skills = mkTest "sws-devenv-enable-sets-ai-skills" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      inherit (result.config.ai) skills;
    in
      skills ? stack-fix
      && skills ? stack-plan
      && skills ? stack-split
      && skills ? stack-submit
      && skills ? stack-summary
      && skills ? stack-test
  );

  # Devenv scope: instructions landed in the devenv pool.
  module-sws-devenv-enable-sets-ai-instructions = mkTest "sws-devenv-enable-sets-ai-instructions" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      inherit (result.config.ai) instructions;
      swsEntries = builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
    in
      builtins.length swsEntries == 1
  );

  # HM (user-global) scope: enable -> ai.skills gets the unprefixed stack-*
  # skills, so each enabled CLI installs them to ~/.claude/skills etc. This
  # is the scope-revert (previously the HM module was git-config only).
  module-sws-hm-enable-sets-ai-skills = mkTest "sws-hm-enable-sets-ai-skills" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      inherit (result.config.ai) skills;
    in
      skills ? stack-fix
      && skills ? stack-plan
      && skills ? stack-split
      && skills ? stack-submit
      && skills ? stack-summary
      && skills ? stack-test
  );

  # HM (user-global) scope: enable -> the routing-table instruction lands in
  # ai.instructions (-> ~/.claude/CLAUDE.md, ~/.kiro/steering/, ...).
  module-sws-hm-enable-sets-ai-instructions = mkTest "sws-hm-enable-sets-ai-instructions" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      inherit (result.config.ai) instructions;
      swsEntries = builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
    in
      builtins.length swsEntries == 1
  );

  # Git config applies when preset is "minimal".
  module-sws-git-config-minimal = mkTest "sws-git-config-minimal" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "minimal";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      (gitSettings ? branchless)
      && (gitSettings ? pull)
      && (gitSettings ? rebase)
  );

  # Git config applies when preset is "full" (includes extended settings).
  module-sws-git-config-full = mkTest "sws-git-config-full" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "full";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      (gitSettings ? branchless)
      && (gitSettings ? diff)
      && (gitSettings ? fetch)
      && (gitSettings ? push)
      && (gitSettings ? revise)
  );

  # Git config NOT set when preset is "none".
  module-sws-git-config-none = mkTest "sws-git-config-none" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "none";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      !(gitSettings ? branchless)
  );

  # References are bundled as REAL files inside each skill dir (deref'd at
  # build) — NOT written as separate .claude/references/* files anymore.
  # This guards the dangling-symlink regression: the skill's references must
  # resolve to real, present files.
  module-sws-skill-references-resolve = mkTest "sws-skill-references-resolve" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      skillPath = result.config.ai.skills.stack-fix;
    in
      builtins.pathExists "${skillPath}/SKILL.md"
      && builtins.pathExists "${skillPath}/references/git-absorb.md"
      && builtins.pathExists "${skillPath}/references/git-branchless.md"
  );

  # ── living-workflow module (skill packaging + XDG state) ─────────
  #
  # HM is the PRIMARY scope (user-global), INVERTING the sws choice (sws keeps
  # skills in its devenv module; living-workflow's HM module installs
  # user-global). The skill is Nix-GENERATED (bakes the XDG state base into
  # SKILL.md) and fed to ai.skills as its store-path STRING — the value shape
  # every consumer (upstream claude mkSkillEntry, our mkSkillEntries, the devenv
  # walker) materializes as a recursive DIRECTORY.

  # Default: living-workflow.enable defaults to false.
  module-living-workflow-default-disabled = mkTest "living-workflow-default-disabled" (
    let
      result = evalHm {};
    in
      !(result.config.living-workflow.enable or true)
  );

  # HM (primary): enable -> ai.skills.living-workflow -> upstream
  # programs.claude-code.skills.living-workflow (end-to-end fanout).
  module-living-workflow-hm-enable-sets-skill = mkTest "living-workflow-hm-enable-sets-skill" (
    let
      result = evalHm {
        ai.claude.enable = true;
        living-workflow.enable = true;
      };
    in
      result.config.programs.claude-code.skills ? living-workflow
  );

  # Kiro HM: the generated store-path string must materialize as a recursive
  # DIRECTORY (home.file.".kiro/skills/living-workflow"), NOT trip the
  # isPath/isString trap that would write it as a single SKILL.md file. Asserts
  # the directory key present AND the single-file trap key absent. (Forces IFD:
  # readFileType builds the tiny skill derivation.)
  module-living-workflow-kiro-hm-writes-skill-dir = mkTest "living-workflow-kiro-hm-writes-skill-dir" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        living-workflow.enable = true;
      };
      files = result.config.home.file;
    in
      (files ? ".kiro/skills/living-workflow")
      && !(files ? ".kiro/skills/living-workflow/SKILL.md")
  );

  # Devenv parity: enable in the devenv module contributes to ai.skills too
  # (config-parity rule; separate eval from HM).
  module-living-workflow-devenv-enable-sets-skill = mkTest "living-workflow-devenv-enable-sets-skill" (
    let
      result = evalDevenv {living-workflow.enable = true;};
    in
      result.config.ai.skills ? living-workflow
  );

  # Disabled -> absent: with living-workflow off, no living-workflow skill is
  # contributed even when an ecosystem is enabled.
  module-living-workflow-disabled-no-skill = mkTest "living-workflow-disabled-no-skill" (
    let
      result = evalHm {ai.kiro.enable = true;};
    in
      !(result.config.ai.skills ? living-workflow)
  );

  # ── services.mcp-servers module ──────────────────────────────────

  # Default: all servers are disabled.
  module-mcp-services-default-disabled = mkTest "mcp-services-default-disabled" (
    let
      result = evalHm {};
      inherit (result.config.services.mcp-servers) servers;
    in
      !(servers.context7-mcp.enable or true)
      && !(servers.github-mcp.enable or true)
      && !(servers.serena-mcp.enable or true)
  );

  # Server option tree has expected structure.
  module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (
    let
      result = evalHm {};
      inherit (result.config.services.mcp-servers) servers;
    in
      servers ? context7-mcp
      && servers ? effect-mcp
      && servers ? fetch-mcp
      && servers ? git-intel-mcp
      && servers ? git-mcp
      && servers ? github-mcp
      && servers ? gitlab-mcp
      && servers ? kagi-mcp
      && servers ? nixos-mcp
      && servers ? openmemory-mcp
      && servers ? sequential-thinking-mcp
      && servers ? serena-mcp
      && servers ? sympy-mcp
  );

  # tools output is empty when no servers enabled.
  module-mcp-services-tools-empty-when-disabled = mkTest "mcp-services-tools-empty-when-disabled" (
    let
      result = evalHm {};
    in
      result.config.services.mcp-servers.tools == {}
  );

  # mcpConfig output is empty when no servers enabled.
  module-mcp-services-mcpconfig-empty-when-disabled = mkTest "mcp-services-mcpconfig-empty-when-disabled" (
    let
      result = evalHm {};
    in
      result.config.services.mcp-servers.mcpConfig.mcpServers == {}
  );

  # Credential rotation: enabling a file-credentialed HTTP server emits a
  # restart-on-rotation activation entry that fingerprints the secret path
  # and targets the matching systemd user unit.
  module-mcp-services-rotation-restart-entry = mkTest "mcp-services-rotation-restart-entry" (
    let
      result = evalHm {
        services.mcp-servers.servers.github-mcp = {
          enable = true;
          settings.credentials.file = "/run/secrets/gh-token";
        };
      };
      activation = result.config.home.activation.mcpRestartOnSecretRotation or null;
    in
      activation
      != null
      && lib.hasInfix "mcp-github-mcp.service" (activation.text or "")
      && lib.hasInfix "sha256sum" (activation.text or "")
      && lib.hasInfix "/run/secrets/gh-token" (activation.text or "")
  );

  # DRY-RUN INERTNESS. Every MUTATING command in the rotation script must be
  # routed through home-manager's `run` helper, which echoes instead of
  # executing when DRY_RUN is set. Reads stay unwrapped on purpose, so a dry
  # run still evaluates its conditions and can report accurately.
  #
  # The NEGATIVE assertion is the load-bearing one. `printf … > "$hash_file"`
  # is the exact form this replaced, and it is what a future "simplification"
  # of the tee would reintroduce: `run` wraps a COMMAND AND ITS ARGUMENTS, so
  # a shell redirection attached to it is performed by the CALLING shell and
  # writes on a dry run regardless. Writing the hash during a dry run is worse
  # than merely failing to be inert -- the next REAL activation then sees an
  # unchanged hash and skips a restart that was genuinely needed, so the dry
  # run silently destroys pending rotation work.
  #
  # The positive assertions double as the CONTROL for the negative: they prove
  # the infix match reaches this script at all, so a passing negative cannot
  # be a match against an empty or wrongly-scoped string.
  module-mcp-services-rotation-dry-run-routed = mkTest "mcp-services-rotation-dry-run-routed" (
    let
      result = evalHm {
        services.mcp-servers.servers.github-mcp = {
          enable = true;
          settings.credentials.file = "/run/secrets/gh-token";
        };
      };
      text = result.config.home.activation.mcpRestartOnSecretRotation.text or "";
      allLines = lib.splitString "\n" text;
      # COMMENT LINES ARE EXCLUDED, and that is not incidental tidiness: the
      # emitted script carries a comment naming `printf > "$hash_file"` as the
      # form to avoid, so a scan over raw lines matches the very prose warning
      # against the defect and fails a correct script. Same shape as the
      # repo's bare-commands scan, which is per-line and therefore reads
      # comments too.
      lines = lib.filter (l: builtins.match "[[:space:]]*#.*" l == null) allLines;
      # Matched per LINE and WITHOUT interpolating any store path. Building
      # the needle from `${pkgs.coreutils}` instead would drag store-path
      # string context into this check's own derivation, which nix rejects
      # outright -- the assertion cannot reference a store path.
      runs = frag: lib.any (l: lib.hasInfix "run " l && lib.hasInfix frag l) lines;
    in
      # LINUX-GATED, deliberately. The module emits this entry only under
      # `pkgs.stdenv.isLinux` (systemd user units), so on darwin the entry does
      # not exist, `text` is empty and every assertion below would be false --
      # a check that fails by construction on one required platform. The
      # sibling rotation test lacks this guard and is a recorded aarch64-darwin
      # failure blocking `--all-systems`; adding a second one would deepen that
      # blocker rather than merely inherit it.
      !pkgs.stdenv.isLinux
      || (
        runs "/bin/mkdir -p"
        && runs "/bin/chmod 700"
        && runs "/bin/systemctl --user restart"
        && lib.any (l: lib.hasInfix "| run --quiet " l && lib.hasInfix "/bin/tee -- \"$hash_file\"" l) lines
        && !(lib.any (l: lib.hasInfix "> \"$hash_file\"" l) lines)
      )
  );

  # Helper-based credentials have no stable file to fingerprint, so they
  # contribute no rotation entry (the path-based restart cannot apply).
  module-mcp-services-rotation-skips-helper-creds = mkTest "mcp-services-rotation-skips-helper-creds" (
    let
      result = evalHm {
        services.mcp-servers.servers.github-mcp = {
          enable = true;
          settings.credentials.helper = "/run/wrappers/gh-token-helper";
        };
      };
    in
      !(result.config.home.activation ? mcpRestartOnSecretRotation)
  );

  # No credentialed services -> no rotation activation entry (inert).
  module-mcp-services-rotation-absent-without-creds = mkTest "mcp-services-rotation-absent-without-creds" (
    let
      result = evalHm {};
    in
      !(result.config.home.activation ? mcpRestartOnSecretRotation)
  );

  # openmemory devAllowNoAuth is a discoverable typed setting (guards the
  # no-auth serve knob added for the HTTP daemon flip). Its emission into
  # OM_DEV_ALLOW_NO_AUTH lives in the isLinux-gated systemd http env, so it
  # is verified separately by a settingsToEnv eval; this test stays
  # platform-independent by asserting on the evaluated option value.
  module-mcp-services-openmemory-dev-allow-no-auth = mkTest "mcp-services-openmemory-dev-allow-no-auth" (
    let
      result = evalHm {
        services.mcp-servers.servers.openmemory-mcp = {
          enable = true;
          settings.devAllowNoAuth = true;
        };
      };
    in
      result.config.services.mcp-servers.servers.openmemory-mcp.settings.devAllowNoAuth == true
  );

  # Enabling openmemory-mcp emits a NATIVE-HTTP mcpConfig entry (not a
  # bridge) pointing at openmemory-mcp-serve's /mcp -- the daemon URL the
  # consumer inherits for the stdio->http flip.
  module-mcp-services-openmemory-http-entry = mkTest "mcp-services-openmemory-http-entry" (
    let
      result = evalHm {
        services.mcp-servers.servers.openmemory-mcp.enable = true;
      };
      entry = result.config.services.mcp-servers.mcpConfig.mcpServers.openmemory-mcp or null;
    in
      entry
      != null
      && entry.type == "http"
      && lib.hasSuffix ":19758/mcp" entry.url
  );

  # ── Attrs-shape ai.rules / ai.<cli>.rules (unified transformer) ───

  # Claude HM: top-level ai.rules → .claude/rules/<name>.md with paths frontmatter.
  module-claude-hm-writes-rules-from-top-level = mkTest "claude-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.rules.code-style = {
          text = "Use consistent formatting.";
          paths = ["src/**"];
        };
      };
      ruleFile = result.config.home.file.".claude/rules/code-style.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Use consistent formatting" (ruleFile.text or "")
      && lib.hasInfix "paths:" (ruleFile.text or "")
      && lib.hasInfix "src/**" (ruleFile.text or "")
  );

  # Kiro HM: top-level ai.rules → a `<name>.md` steering entry with
  # inclusion frontmatter.
  module-kiro-hm-writes-rules-from-top-level = mkTest "kiro-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.rules.testing = {
          text = "Write tests for all new features.";
          paths = ["**/*.test.*"];
        };
      };
      ruleFile = result.config.ai.kiro.steeringFiles."testing.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Write tests for all new features" (ruleFile.text or "")
      && lib.hasInfix "inclusion: fileMatch" (ruleFile.text or "")
  );

  # Copilot HM: top-level ai.rules → .github/instructions/<name>.instructions.md.
  module-copilot-hm-writes-rules-from-top-level = mkTest "copilot-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.rules.security = {
          text = "Validate all user input.";
          paths = ["**/*.ts"];
        };
      };
      ruleFile = result.config.home.file.".github/instructions/security.instructions.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Validate all user input" (ruleFile.text or "")
      && lib.hasInfix "applyTo:" (ruleFile.text or "")
  );

  # Per-CLI rules merge with top-level; per-CLI wins on collision.
  module-kiro-hm-per-cli-rules-wins = mkTest "kiro-hm-per-cli-rules-wins" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.same-name.text = "Per-CLI wins.";
        };
        ai.rules.same-name.text = "Top-level loses.";
      };
      ruleFile = result.config.ai.kiro.steeringFiles."same-name.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Per-CLI wins" (ruleFile.text or "")
      && !(lib.hasInfix "Top-level loses" (ruleFile.text or ""))
  );

  # Rules with null paths → unconditional (no frontmatter scoping).
  module-claude-hm-rules-null-paths-no-frontmatter = mkTest "claude-hm-rules-null-paths-no-frontmatter" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.rules.always-on.text = "Loaded unconditionally.";
      };
      ruleFile = result.config.home.file.".claude/rules/always-on.md" or null;
    in
      ruleFile != null && !(lib.hasInfix "paths:" (ruleFile.text or ""))
  );

  # Devenv parity: Kiro devenv emits ai.rules to steering entries.
  module-kiro-devenv-writes-rules = mkTest "kiro-devenv-writes-rules" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.rules.testing = {
          text = "Write tests.";
          paths = ["**/*.test.*"];
        };
      };
      ruleFile = result.config.ai.kiro.steeringFiles."testing.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Write tests" (ruleFile.text or "")
  );

  # Copilot HM: per-CLI context → `<configDir>/<contextFilename>`.
  module-copilot-hm-writes-context = mkTest "copilot-hm-writes-context" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          context = "Copilot-specific context.";
        };
      };
      contextFile =
        result.config.home.file.".copilot/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Copilot-specific context" (contextFile.text or "")
  );

  # Copilot HM: top-level ai.context fans out when per-CLI unset.
  module-copilot-hm-top-level-context-fallback = mkTest "copilot-hm-top-level-context-fallback" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile =
        result.config.home.file.".copilot/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # Copilot devenv parity.
  module-copilot-devenv-writes-context = mkTest "copilot-devenv-writes-context" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          context = "Copilot devenv context.";
        };
      };
      contextFile =
        result.config.files.".github/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Copilot devenv context" (contextFile.text or "")
  );

  # HM: ai.claude.plugins routes to programs.claude-code.plugins as an
  # ATTRSET, key and value intact. The per-entry mkDefault in mkClaude
  # must resolve away, leaving the bare source.
  module-claude-hm-plugins-route-to-upstream = mkTest "claude-hm-plugins-route-to-upstream" (
    let
      src = ./../packages/stacked-workflows/skills/stack-fix;
      result = evalHm {
        ai.claude = {
          enable = true;
          plugins.my-plugin = src;
        };
      };
      upstream = result.config.programs.claude-code.plugins or {};
    in
      lib.attrNames upstream == ["my-plugin"] && upstream.my-plugin == src
  );

  # HM: the ATTRIBUTE NAME — not the source's base name — is what becomes
  # the plugin's on-disk directory name. This is the whole point of the
  # list → attrset conversion: upstream's list form derives each name from
  # `baseNameOf` the entry, so a bare flake-input store path yields an
  # unstable `<hash>-source` that is renamed by every unrelated input bump.
  #
  # Upstream (home-manager modules/programs/claude-code, verified at rev
  # cbb77679) consumes the attrset via `lib.mapAttrsToList mkPluginEntry`
  # and links each entry at `<configDir>/skills/<name>`, so the key here IS
  # the delivered directory name. Our boundary is the key handed to
  # upstream; this asserts a key that shares nothing with its value's store
  # base name still arrives verbatim, and that no name is derived from the
  # source.
  module-claude-hm-plugins-key-is-directory-name = mkTest "claude-hm-plugins-key-is-directory-name" (
    let
      # A package whose store base name (…-hello-<version>) is nothing like
      # the key, standing in for a flake-input root.
      pluginPkg = pkgs.hello;
      result = evalHm {
        ai.claude = {
          enable = true;
          plugins.remember = pluginPkg;
        };
      };
      upstream = result.config.programs.claude-code.plugins or {};
      # `unsafeDiscardStringContext` mirrors upstream's own
      # `derivePluginName`; without it the store-path context makes this
      # illegal to use as an attribute name.
      derivedName =
        builtins.unsafeDiscardStringContext (baseNameOf (toString pluginPkg));
    in
      lib.attrNames upstream
      == ["remember"]
      && upstream.remember == pluginPkg
      && !(upstream ? ${derivedName})
  );

  # HM: ai.claude.marketplaces routes to programs.claude-code.marketplaces
  # via identity translation. Regression guard.
  module-claude-hm-marketplaces-route-to-upstream = mkTest "claude-hm-marketplaces-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          marketplaces.my-shelf = ./../packages/stacked-workflows/skills/stack-fix;
        };
      };
      upstream = result.config.programs.claude-code.marketplaces or {};
    in
      upstream ? my-shelf
  );

  # HM: ai.claude.outputStyles routes to programs.claude-code.outputStyles.
  module-claude-hm-output-styles-route-to-upstream = mkTest "claude-hm-output-styles-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          outputStyles.concise = "Keep answers under 3 sentences.";
        };
      };
      upstream = result.config.programs.claude-code.outputStyles or {};
    in
      (upstream.concise or null) == "Keep answers under 3 sentences."
  );

  # HM: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
  module-kiro-hm-top-level-lsp-fanout = mkTest "kiro-hm-top-level-lsp-fanout" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.lspServers.nixd = {
          command = "nixd";
          args = [];
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # Devenv: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
  module-kiro-devenv-top-level-lsp-fanout = mkTest "kiro-devenv-top-level-lsp-fanout" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.lspServers.nixd = {
          command = "nixd";
          args = [];
        };
      };
      lspFile = result.config.files.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # HM: top-level ai.lspServers fans out to Copilot's lsp-config.json.
  module-copilot-hm-top-level-lsp-fanout = mkTest "copilot-hm-top-level-lsp-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.lspServers.typescript = {
          command = "typescript-language-server";
          args = ["--stdio"];
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # Devenv: top-level ai.lspServers fans out to Copilot's lsp-config.json.
  module-copilot-devenv-top-level-lsp-fanout = mkTest "copilot-devenv-top-level-lsp-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.lspServers.typescript = {
          command = "typescript-language-server";
          args = ["--stdio"];
        };
      };
      lspFile = result.config.files.".config/github-copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # HM: per-CLI ai.kiro.lspServers overrides top-level ai.lspServers on
  # name collision. Kiro-specific override wins.
  module-kiro-hm-per-cli-lsp-overrides-top-level = mkTest "kiro-hm-per-cli-lsp-overrides-top-level" (
    let
      result = evalHm {
        ai = {
          kiro.enable = true;
          lspServers.nixd = {
            command = "nixd-top-level";
          };
          kiro.lspServers.nixd = {
            command = "nixd-kiro-specific";
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd-kiro-specific" (lspFile.text or "")
      && !(lib.hasInfix "nixd-top-level" (lspFile.text or ""))
  );

  # HM: top-level ai.lspServers fans out to Claude's programs.claude-code.lspServers.
  # Closes the LSP fanout story — Claude now receives the merged pool via
  # upstream HM's own surface (upstream writes into ~/.claude/settings.json).
  module-claude-hm-top-level-lsp-fanout = mkTest "claude-hm-top-level-lsp-fanout" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.lspServers.nixd = {
          command = "nixd";
          args = [];
        };
      };
      upstream = result.config.programs.claude-code.lspServers or {};
    in
      (upstream.nixd.command or null) == "nixd"
  );

  # HM: ai.claude.lspServers per-CLI overrides top-level ai.lspServers on
  # name collision. Claude-specific override wins.
  module-claude-hm-per-cli-lsp-overrides-top-level = mkTest "claude-hm-per-cli-lsp-overrides-top-level" (
    let
      result = evalHm {
        ai = {
          claude.enable = true;
          lspServers.nixd = {
            command = "nixd-top-level";
          };
          claude.lspServers.nixd = {
            command = "nixd-claude-specific";
          };
        };
      };
      upstream = result.config.programs.claude-code.lspServers or {};
    in
      (upstream.nixd.command or null) == "nixd-claude-specific"
  );

  # HM: top-level ai.environmentVariables fans out to Kiro wrapper + Copilot wrapper.
  module-kiro-hm-top-level-env-fanout = mkTest "kiro-hm-top-level-env-fanout" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_FOO = "bar";
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "kiro-cli-wrapped"
  );

  # Devenv: top-level ai.environmentVariables fans to Kiro env blob.
  module-kiro-devenv-top-level-env-fanout = mkTest "kiro-devenv-top-level-env-fanout" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_DEBUG = "1";
      };
    in
      (result.config.env.KIRO_DEBUG or null) == "1"
  );

  # HM: top-level ai.environmentVariables triggers Copilot wrapper.
  module-copilot-hm-top-level-env-fanout = mkTest "copilot-hm-top-level-env-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_FOO = "bar";
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  # Devenv: top-level ai.environmentVariables fans to Copilot env blob.
  module-copilot-devenv-top-level-env-fanout = mkTest "copilot-devenv-top-level-env-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_DEBUG = "1";
      };
    in
      (result.config.env.COPILOT_DEBUG or null) == "1"
  );

  # Devenv: per-CLI ai.kiro.environmentVariables wins over top-level on name collision.
  module-kiro-devenv-per-cli-env-wins = mkTest "kiro-devenv-per-cli-env-wins" (
    let
      result = evalDevenv {
        ai = {
          kiro.enable = true;
          environmentVariables.SHARED = "top-level";
          kiro.environmentVariables.SHARED = "kiro-specific";
        };
      };
    in
      (result.config.env.SHARED or null) == "kiro-specific"
  );

  # Copilot HM: typed LSP with `extensions` emits fileExtensions
  # mapping. Per-ecosystem Copilot translator (mkCopilotLspConfig).
  module-copilot-hm-lsp-file-extensions = mkTest "copilot-hm-lsp-file-extensions" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
            extensions = ["ts" "tsx"];
          };
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "fileExtensions" (lspFile.text or "")
      && lib.hasInfix "\".ts\"" (lspFile.text or "")
      && lib.hasInfix "\".tsx\"" (lspFile.text or "")
  );

  # Claude HM: typed LSP with `extensions` emits extensionToLanguage
  # mapping via mkClaudeLspConfig.
  module-claude-hm-lsp-extension-to-language = mkTest "claude-hm-lsp-extension-to-language" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          lspServers.go = {
            command = "gopls";
            args = ["serve"];
            extensions = ["go"];
          };
        };
      };
      upstream = result.config.programs.claude-code.lspServers or {};
      entry = upstream.go or {};
    in
      (entry.command or null)
      == "gopls"
      && ((entry.extensionToLanguage or {}).".go" or null)
      == "go"
  );

  # Kiro HM: package-based declaration renders `${package}/bin/${binary}`.
  # Exercises the package+binary resolution branch.
  module-kiro-hm-lsp-package-command-rendering = mkTest "kiro-hm-lsp-package-command-rendering" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          lspServers.hello-lsp = {
            package = pkgs.hello;
            binary = "hello";
            args = [];
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "/bin/hello" (lspFile.text or "")
  );

  # HM: top-level ai.agents fans out to Claude's programs.claude-code.agents.
  module-claude-hm-top-level-agents-fanout = mkTest "claude-hm-top-level-agents-fanout" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.agents.reviewer = "# Reviewer\n\nReview carefully.";
      };
      upstream = result.config.programs.claude-code.agents or {};
    in
      (upstream.reviewer or null)
      == "# Reviewer\n\nReview carefully."
  );

  # HM: top-level ai.agents fans out to Copilot's agents file write.
  module-copilot-hm-top-level-agents-fanout = mkTest "copilot-hm-top-level-agents-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.agents.reviewer = "# Reviewer";
      };
      agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Reviewer" (agentFile.text or "")
  );

  # Devenv: top-level ai.agents fans out to Copilot's .github/agents.
  module-copilot-devenv-top-level-agents-fanout = mkTest "copilot-devenv-top-level-agents-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.agents.reviewer = "# Reviewer";
      };
      agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Reviewer" (agentFile.text or "")
  );

  # Precedence: ai.claude.agents wins over ai.agents on name collision.
  module-claude-hm-per-cli-agents-wins = mkTest "claude-hm-per-cli-agents-wins" (
    let
      result = evalHm {
        ai = {
          claude.enable = true;
          agents.reviewer = "# Top-level";
          claude.agents.reviewer = "# Claude-specific";
        };
      };
      upstream = result.config.programs.claude-code.agents or {};
    in
      (upstream.reviewer or null) == "# Claude-specific"
  );

  # Kiro independence: top-level ai.agents is markdown-shape, Kiro agents
  # are JSON-shape. Setting ai.agents.foo when ai.kiro.enable = true
  # must NOT produce a .kiro/agents/foo file.
  module-kiro-ignores-top-level-agents = mkTest "kiro-ignores-top-level-agents" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.agents.reviewer = "# Reviewer markdown";
      };
    in
      !(result.config.home.file ? ".kiro/agents/reviewer.json")
      && !(result.config.home.file ? ".kiro/agents/reviewer.md")
  );

  # HM: ai.claude.commands routes to programs.claude-code.commands via
  # identity translation. Claude-only — Kiro and Copilot have no
  # commands concept, so no top-level fanout.
  module-claude-hm-commands-route-to-upstream = mkTest "claude-hm-commands-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          commands.fix-issue = "# Fix issue\n\nSteps…";
        };
      };
      upstream = result.config.programs.claude-code.commands or {};
    in
      (upstream.fix-issue or null) == "# Fix issue\n\nSteps…"
  );

  # HM: ai.claude.hookScripts (inline script bodies) routes to
  # programs.claude-code.hooks via identity translation.
  module-claude-hm-hookscripts-route-to-upstream = mkTest "claude-hm-hookscripts-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hookScripts.pre-edit = "#!/usr/bin/env bash\necho edit\n";
        };
      };
      upstream = result.config.programs.claude-code.hooks or {};
    in
      (upstream.pre-edit or null) == "#!/usr/bin/env bash\necho edit\n"
  );

  # HM: the typed ai.claude.hooks event map lowers into
  # programs.claude-code.settings.hooks via the shared helper.
  module-claude-hm-hooks-lower-to-settings = mkTest "claude-hm-hooks-lower-to-settings" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [{command = "validate";}];
            }
          ];
        };
      };
      settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
      block = builtins.head (settingsHooks.PreToolUse or []);
      handler = builtins.head (block.hooks or []);
    in
      block.matcher == "Bash" && handler.command == "validate" && handler.type == "command"
  );

  # Compose-not-clobber invariant (decision #3): settings.json's formats.json
  # merge CONCATENATES same-event hook lists across writers, so the typed event
  # map and the legacy settings.hooks escape hatch coexist. Asserted against the
  # REAL type — the module-eval `attrsOf anything` stub throws on this merge where
  # formats.json concatenates, so it cannot model it. Mirrors the factory pattern:
  # a whole `settings =` write plus a nested `settings.hooks =` write (both
  # backends lower this way).
  module-claude-hooks-settings-json-compose = mkTest "claude-hooks-settings-json-compose" (
    let
      jsonType = (pkgs.formats.json {}).type;
      ev = lib.evalModules {
        modules = [
          {options.settings = lib.mkOption {type = jsonType;};}
          {config.settings = {hooks.PreToolUse = [{matcher = "legacy";}];};}
          {config.settings.hooks.PreToolUse = [{matcher = "typed";}];}
        ];
      };
      matchers = map (b: b.matcher or null) ev.config.settings.hooks.PreToolUse;
    in
      builtins.length matchers == 2 && builtins.elem "legacy" matchers && builtins.elem "typed" matchers
  );

  # Devenv: hookScripts → a `.claude/hooks/<name>` file; the legacy
  # settings.hooks escape hatch → settings.json.hooks (verbatim). Neither feeds
  # claude.code.hooks anymore (approach B — the old type-invalid mis-feed is gone).
  module-claude-devenv-hookscripts-and-settings-split = mkTest "claude-devenv-hookscripts-and-settings-split" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.hooks.from-settings = [{matcher = "X";}];
          hookScripts.from-top = "#!/usr/bin/env bash\necho from-top\n";
        };
      };
      settingsHooks = ((result.config.files.".claude/settings.json" or {}).json or {}).hooks or {};
      scriptFile = result.config.files.".claude/hooks/from-top" or null;
      upstream = result.config.claude.code.hooks or {};
    in
      (settingsHooks.from-settings or null)
      != null
      && scriptFile != null
      && (scriptFile.text or null) == "#!/usr/bin/env bash\necho from-top\n"
      && !(upstream ? from-top)
  );

  # Typed ai.claude.hooks event map: accepts the settings.json-shaped
  # per-event structure (soft-enum event key → list of matcher blocks →
  # list of typed handlers) and carries it through. No lowering asserted
  # here — that is Commit 3/4.
  module-claude-hooks-typed-event-map = mkTest "claude-hooks-typed-event-map" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [{command = "true";}];
            }
          ];
        };
      };
      block = builtins.head (result.config.ai.claude.hooks.PreToolUse or []);
      handler = builtins.head (block.hooks or []);
    in
      block.matcher == "Bash" && handler.command == "true" && handler.type == "command"
  );

  # S1: a handler `command` accepts a package and coerces to its getExe path
  # (its supporting files ride the /nix/store closure at absolute paths).
  module-claude-hooks-command-accepts-package = mkTest "claude-hooks-command-accepts-package" (
    let
      pkg = pkgs.writeShellApplication {
        name = "demo-hook";
        text = "exit 0";
      };
      result = evalHm {
        ai.claude = {
          enable = true;
          hooks.PostToolUse = [{hooks = [{command = pkg;}];}];
        };
      };
      handler = builtins.head (builtins.head result.config.ai.claude.hooks.PostToolUse).hooks;
    in
      builtins.isString handler.command && lib.hasSuffix "/bin/demo-hook" handler.command
  );

  # Devenv: the typed ai.claude.hooks event map lowers into
  # files.".claude/settings.json".json.hooks via the shared helper
  # (approach B — no claude.code.hooks records).
  module-claude-devenv-hooks-lower-to-settings = mkTest "claude-devenv-hooks-lower-to-settings" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [{command = "validate";}];
            }
          ];
        };
      };
      settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
      block = builtins.head (settingsJson.hooks.PreToolUse or []);
      handler = builtins.head (block.hooks or []);
    in
      block.matcher == "Bash" && handler.command == "validate" && handler.type == "command"
  );

  # Devenv: hookScripts (inline bodies) become standalone
  # .claude/hooks/<name> files (greenfield; NOT claude.code.hooks).
  module-claude-devenv-hookscripts-write-files = mkTest "claude-devenv-hookscripts-write-files" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          hookScripts.my-hook = "#!/usr/bin/env bash\nexit 0\n";
        };
      };
      f = result.config.files.".claude/hooks/my-hook" or null;
    in
      f != null && (f.text or null) == "#!/usr/bin/env bash\nexit 0\n"
  );

  # ── Collision-as-failure ──────────────────────────────────────
  # Shared ai.<pool> merging with ai.<cli>.<pool> emits NixOS
  # assertions on duplicate keys. See lib/ai/ai-common.nix
  # mergeWithCollisionCheck. Applies retroactively to: rules,
  # skills, mcpServers, lspServers, environmentVariables, agents.
  #
  # The assertion always fires (no mkIf cfg.enable gate) so a
  # mis-configured ai.* surface surfaces even when the feature is
  # toggled off.

  # Rules: top-level ai.rules.foo vs per-CLI ai.claude.rules.foo.
  module-claude-rules-collision = mkTest "claude-rules-collision" (
    let
      result = evalHm {
        ai.rules.foo.text = "top";
        ai.claude = {
          enable = true;
          rules.foo.text = "cli";
        };
      };
    in
      lib.any
      (a: lib.hasInfix "rules 'foo' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Rules: collision fires even when the CLI is disabled.
  module-claude-rules-collision-without-enable = mkTest "claude-rules-collision-without-enable" (
    let
      result = evalHm {
        ai.rules.foo.text = "top";
        ai.claude.rules.foo.text = "cli";
      };
    in
      lib.any
      (a: lib.hasInfix "rules 'foo' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Skills.
  module-kiro-skills-collision = mkTest "kiro-skills-collision" (
    let
      result = evalHm {
        ai.skills.my-skill = ./../packages/stacked-workflows/skills/stack-fix;
        ai.kiro = {
          enable = true;
          skills.my-skill = ./../packages/stacked-workflows/skills/stack-fix;
        };
      };
    in
      lib.any
      (a: lib.hasInfix "skills 'my-skill' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # MCP servers.
  module-copilot-mcpservers-collision = mkTest "copilot-mcpservers-collision" (
    let
      result = evalHm {
        ai.mcpServers.my-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
        ai.copilot = {
          enable = true;
          mcpServers.my-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
      };
    in
      lib.any
      (a: lib.hasInfix "mcpServers 'my-server' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # LSP servers.
  module-claude-lspservers-collision = mkTest "claude-lspservers-collision" (
    let
      result = evalHm {
        ai.lspServers.nixd = {
          command = "nixd";
        };
        ai.claude = {
          enable = true;
          lspServers.nixd = {
            command = "nixd";
          };
        };
      };
    in
      lib.any
      (a: lib.hasInfix "lspServers 'nixd' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Environment variables.
  module-copilot-envvar-collision = mkTest "copilot-envvar-collision" (
    let
      result = evalHm {
        ai.environmentVariables.FOO = "top";
        ai.copilot = {
          enable = true;
          environmentVariables.FOO = "cli";
        };
      };
    in
      lib.any
      (a: lib.hasInfix "environmentVariables 'FOO' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Agents.
  module-claude-agents-collision = mkTest "claude-agents-collision" (
    let
      result = evalHm {
        ai.agents.helper = "Top-level agent";
        ai.claude = {
          enable = true;
          agents.helper = "Claude-only agent";
        };
      };
    in
      lib.any
      (a: lib.hasInfix "agents 'helper' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Devenv collision surfaces through the same helper.
  module-claude-devenv-rules-collision = mkTest "claude-devenv-rules-collision" (
    let
      result = evalDevenv {
        ai.rules.foo.text = "top";
        ai.claude = {
          enable = true;
          rules.foo.text = "cli";
        };
      };
    in
      lib.any
      (a: lib.hasInfix "rules 'foo' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Distinct keys do NOT trigger an assertion.
  module-claude-rules-no-collision = mkTest "claude-rules-no-collision" (
    let
      result = evalHm {
        ai.rules.from-top.text = "top";
        ai.claude = {
          enable = true;
          rules.from-cli.text = "cli";
        };
      };
    in
      !(lib.any
        (a: !a.assertion && lib.hasInfix "declared in both" a.message)
        result.config.assertions)
  );

  # ── ai.*.rulesDir Dir helper ──────────────────────────────────
  # See lib/ai/dir-helpers.nix + lib/ai/sharedOptions.nix + the
  # per-CLI baseline option in hmTransform/devenvTransform.
  # Plan §4: polymorphic `path | { path, filter? }`, default
  # filter keeps `.md`, basename minus `.md` becomes the key
  # (fixes the `.md.md` doubled-extension bug).

  # Path-only form: `ai.kiro.rulesDir = ./fixtures/kiro-steering;`
  # expands to three steering entries (alpha, beta, gamma). notes.txt
  # is dropped by the default `.md` filter. Keys land at `<name>.md` —
  # no `.md.md` (vacuous-scan negatives re-pointed at attrNames of
  # steeringFiles).
  module-kiro-rulesdir-path-form = mkTest "kiro-rulesdir-path-form" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rulesDir = ./fixtures/kiro-steering;
        };
      };
      steering = result.config.ai.kiro.steeringFiles;
      hasAlpha = steering ? "alpha.md";
      hasBeta = steering ? "beta.md";
      hasGamma = steering ? "gamma.md";
      # Key is stripped — no `.md.md` name ever emitted.
      noDoubledMd =
        !(lib.any (p: lib.hasSuffix ".md.md" p) (lib.attrNames steering));
      # notes.txt is filtered out (default keeps only `.md`).
      noNotes = !(steering ? "notes.md");
    in
      hasAlpha
      && hasBeta
      && hasGamma
      && noDoubledMd
      && noNotes
  );

  # Submodule form with custom filter (keep only `alpha.md`).
  module-kiro-rulesdir-submodule-filter = mkTest "kiro-rulesdir-submodule-filter" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rulesDir = {
            path = ./fixtures/kiro-steering;
            filter = name: name == "alpha.md";
          };
        };
      };
      steering = result.config.ai.kiro.steeringFiles;
    in
      steering
      ? "alpha.md"
      && !(steering ? "beta.md")
      && !(steering ? "gamma.md")
  );

  # Top-level `ai.rulesDir` fans out to every enabled CLI via the
  # sharedOptions L1→L2 expansion.
  module-top-level-rulesdir-fans-out-to-kiro = mkTest "top-level-rulesdir-fans-out-to-kiro" (
    let
      result = evalHm {
        ai = {
          kiro.enable = true;
          rulesDir = ./fixtures/kiro-steering;
        };
      };
    in
      result.config.ai.kiro.steeringFiles ? "alpha.md"
  );

  # Collision between Dir-generated and explicit single (same key)
  # fires the shared collision assertion.
  module-kiro-rulesdir-collides-with-explicit-single = mkTest "kiro-rulesdir-collides-with-explicit-single" (
    let
      result = evalHm {
        ai.rules.alpha.text = "explicit top-level";
        ai.kiro = {
          enable = true;
          rulesDir = ./fixtures/kiro-steering;
        };
      };
    in
      lib.any
      (a: lib.hasInfix "rules 'alpha' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Devenv-side rulesDir works the same way (parity).
  module-kiro-devenv-rulesdir-path-form = mkTest "kiro-devenv-rulesdir-path-form" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          rulesDir = ./fixtures/kiro-steering;
        };
      };
      steering = result.config.ai.kiro.steeringFiles;
    in
      steering
      ? "alpha.md"
      && !(lib.any (p: lib.hasSuffix ".md.md" p) (lib.attrNames steering))
  );

  # ── ai.*.skillsDir Dir helper ──────────────────────────────
  # Directory-of-directories; each immediate subdir becomes a
  # skill. See lib/ai/dir-helpers.nix:skillsFromDir.

  # Path-only form fans every subdir into ai.claude.skills.
  module-claude-skillsdir-path-form = mkTest "claude-skillsdir-path-form" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          skillsDir = ./fixtures/claude-skills;
        };
      };
      upstream = result.config.programs.claude-code.skills or {};
    in
      upstream ? skill-a && upstream ? skill-b
  );

  # Submodule form with a filter that excludes skill-b.
  module-claude-skillsdir-filter = mkTest "claude-skillsdir-filter" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          skillsDir = {
            path = ./fixtures/claude-skills;
            filter = name: name == "skill-a";
          };
        };
      };
      upstream = result.config.programs.claude-code.skills or {};
    in
      upstream ? skill-a && !(upstream ? skill-b)
  );

  # Top-level `ai.skillsDir` fans out to every enabled CLI.
  module-top-level-skillsdir-fans-out-to-claude = mkTest "top-level-skillsdir-fans-out-to-claude" (
    let
      result = evalHm {
        ai = {
          claude.enable = true;
          skillsDir = ./fixtures/claude-skills;
        };
      };
      upstream = result.config.programs.claude-code.skills or {};
    in
      upstream ? skill-a && upstream ? skill-b
  );

  # Collision between Dir-generated and explicit single.
  module-claude-skillsdir-collides-with-explicit-single = mkTest "claude-skillsdir-collides-with-explicit-single" (
    let
      result = evalHm {
        ai.skills.skill-a = ./fixtures/claude-skills/skill-a;
        ai.claude = {
          enable = true;
          skillsDir = ./fixtures/claude-skills;
        };
      };
    in
      lib.any
      (a: lib.hasInfix "skills 'skill-a' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # ── ai.*.agentsDir Dir helper ──────────────────────────────
  # Claude + Copilot only; Kiro is excluded because its agent
  # shape is JSON (separate `ai.kiro.agents` / `ai.kiro.agentsDir`
  # surfaces handle that).

  # Path-only form: `ai.claude.agentsDir = ./fixtures/claude-agents;`
  # expands to two entries (agent-one, agent-two). Emission lands
  # at `.claude/agents/<name>.md` via the existing per-agent file
  # emission in mkClaude.
  module-claude-agentsdir-path-form = mkTest "claude-agentsdir-path-form" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          agentsDir = ./fixtures/claude-agents;
        };
      };
      upstream = result.config.programs.claude-code.agents or {};
    in
      upstream ? agent-one && upstream ? agent-two
  );

  # Submodule form with filter.
  module-claude-agentsdir-filter = mkTest "claude-agentsdir-filter" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          agentsDir = {
            path = ./fixtures/claude-agents;
            filter = name: name == "agent-one.md";
          };
        };
      };
      upstream = result.config.programs.claude-code.agents or {};
    in
      upstream ? agent-one && !(upstream ? agent-two)
  );

  # Top-level `ai.agentsDir` fans out to every enabled agent-
  # consumer (Claude, Copilot — NOT kiro).
  module-top-level-agentsdir-fans-out-to-claude = mkTest "top-level-agentsdir-fans-out-to-claude" (
    let
      result = evalHm {
        ai = {
          claude.enable = true;
          agentsDir = ./fixtures/claude-agents;
        };
      };
      upstream = result.config.programs.claude-code.agents or {};
    in
      upstream ? agent-one && upstream ? agent-two
  );

  # Collision between Dir-generated and explicit top-level single.
  module-claude-agentsdir-collides-with-explicit-single = mkTest "claude-agentsdir-collides-with-explicit-single" (
    let
      result = evalHm {
        ai.agents.agent-one = "Explicit top-level agent";
        ai.claude = {
          enable = true;
          agentsDir = ./fixtures/claude-agents;
        };
      };
    in
      lib.any
      (a: lib.hasInfix "agents 'agent-one' declared in both" a.message && !a.assertion)
      result.config.assertions
  );

  # Copilot parity (HM side).
  module-copilot-agentsdir-path-form = mkTest "copilot-agentsdir-path-form" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          agentsDir = ./fixtures/claude-agents;
        };
      };
      files = result.config.home.file;
    in
      files
      ? ".copilot/agents/agent-one.md"
      && files ? ".copilot/agents/agent-two.md"
  );

  # ── ai.claude.hookScriptsDir Dir helper ────────────────────
  # Claude-only per plan §5 (hook scripts are a Claude-specific
  # concept). See lib/ai/dir-helpers.nix:hooksFromDir. Default
  # filter is always-true — hook files are typically
  # extensionless shell scripts, so no `.md`-like suffix strip.

  module-claude-hookscriptsdir-path-form = mkTest "claude-hookscriptsdir-path-form" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hookScriptsDir = ./fixtures/claude-hooks;
        };
      };
      upstream = result.config.programs.claude-code.hooks or {};
    in
      upstream ? pre-edit && upstream ? post-edit
  );

  # Filter excludes post-edit.
  module-claude-hookscriptsdir-filter = mkTest "claude-hookscriptsdir-filter" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hookScriptsDir = {
            path = ./fixtures/claude-hooks;
            filter = name: name == "pre-edit";
          };
        };
      };
      upstream = result.config.programs.claude-code.hooks or {};
    in
      upstream ? pre-edit && !(upstream ? post-edit)
  );

  # Collision: Dir-generated vs explicit `ai.claude.hookScripts.<name>`
  # is NOT a shared-pool collision (hook scripts have no top-level pool),
  # so the module system handles it via the `attrsOf lines` merge.
  # The Dir expansion uses mkDefault so explicit entries win.
  module-claude-hookscriptsdir-explicit-wins-within-layer = mkTest "claude-hookscriptsdir-explicit-wins-within-layer" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hookScripts.pre-edit = "explicit override";
          hookScriptsDir = ./fixtures/claude-hooks;
        };
      };
      upstream = result.config.programs.claude-code.hooks or {};
    in
      upstream.pre-edit == "explicit override"
  );

  # Devenv parity — hookScriptsDir feeds the greenfield .claude/hooks/<name>
  # files (approach B; devenv has no programs.claude-code.hooks equivalent).
  module-claude-devenv-hookscriptsdir-path-form = mkTest "claude-devenv-hookscriptsdir-path-form" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          hookScriptsDir = ./fixtures/claude-hooks;
        };
      };
      files = result.config.files or {};
    in
      files ? ".claude/hooks/pre-edit" && files ? ".claude/hooks/post-edit"
  );

  # ── sourcePath rollback regression guards ──────────────────────
  # `sourcePath` was introduced in fab4e5c and rolled back in this
  # commit per the ai-factory-collision refactor plan §6 (commit 2).
  # Live-edit is deprecated — devenv covers iteration. `text` is
  # required again; rules always bake into the store with
  # transformer-injected frontmatter.

  # HM: inline rule text still bakes and carries frontmatter. Shape pin
  # on the steeringFiles entry: text set, source null (attr-absence
  # checks are meaningless on a submodule — every entry has the attr),
  # strategy = copy (the default).
  module-kiro-hm-rule-text-bakes = mkTest "kiro-hm-rule-text-bakes" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.my-rule.text = "Inline content";
        };
      };
      entry = result.config.ai.kiro.steeringFiles."my-rule.md" or null;
    in
      entry
      != null
      && entry.text != null
      && entry.source == null
      && entry.strategy == "copy"
      && lib.hasInfix "Inline content" entry.text
  );

  # HM: rule.text accepting a path literal still works (resolved to
  # baked text at eval — same shape pin).
  module-kiro-hm-rule-path-bakes = mkTest "kiro-hm-rule-path-bakes" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.rule-from-path.text = ./fixtures/kiro-steering/alpha.md;
        };
      };
      entry = result.config.ai.kiro.steeringFiles."rule-from-path.md" or null;
    in
      entry
      != null
      && entry.text != null
      && entry.source == null
      && entry.strategy == "copy"
      && lib.hasInfix "Alpha steering body" entry.text
  );

  # Negative: `sourcePath` is no longer a known option. Attempting to
  # set it fails module evaluation (tryEval captures the error from
  # strict-evaluating only the target rule's attrs, to avoid a full
  # config-tree walk stack overflow).
  module-kiro-hm-rule-sourcepath-rejected = mkTest "kiro-hm-rule-sourcepath-rejected" (
    let
      attempt = builtins.tryEval (let
        r = evalHm {
          ai.kiro = {
            enable = true;
            rules.my-rule = {
              text = "body";
              sourcePath = "/abs/path/to/my-rule.md";
            };
          };
        };
      in
        builtins.deepSeq r.config.ai.kiro.rules.my-rule true);
    in
      !attempt.success
  );

  module-claude-hm-rule-sourcepath-rejected = mkTest "claude-hm-rule-sourcepath-rejected" (
    let
      attempt = builtins.tryEval (let
        r = evalHm {
          ai.claude = {
            enable = true;
            rules.my-rule = {
              text = "body";
              sourcePath = "/abs/path/to/my-rule.md";
            };
          };
        };
      in
        builtins.deepSeq r.config.ai.claude.rules.my-rule true);
    in
      !attempt.success
  );

  # ── Kimchi (mkAiApp factory participant) ──────────────────────────
  module-kimchi-default-disabled = mkTest "kimchi-default-disabled" (!(evalHm {}).config.ai.kimchi.enable);

  module-kimchi-enable-toggles = mkTest "kimchi-enable-toggles" (evalHm {ai.kimchi.enable = true;}).config.ai.kimchi.enable;

  # Regression lock for the flattenDotKeys bug: config.json must be NESTED
  # JSON, never Kiro-style flat dot keys ("telemetry.enabled").
  module-kimchi-config-json-nested = mkTest "kimchi-config-json-nested" (
    let
      result = evalDevenv {
        ai.kimchi = {
          enable = true;
          settings.telemetry.enabled = false;
        };
      };
      text = result.config.files.".config/kimchi/config.json".text;
    in
      lib.hasInfix ''"telemetry":{"enabled":false}'' text
      && !lib.hasInfix "telemetry.enabled" text
  );

  # Parity: the same config.json surface triggers the HM activation merge.
  module-kimchi-config-json-hm-merge = mkTest "kimchi-config-json-hm-merge" (
    let
      result = evalHm {
        ai.kimchi = {
          enable = true;
          settings.telemetry.enabled = false;
        };
      };
    in
      result.config.home.activation ? kimchiConfigMerge
  );

  # harnessSettings render to harness/settings.json (mutable-state tree).
  module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
    let
      result = evalDevenv {
        ai.kimchi = {
          enable = true;
          harnessSettings.resources."tools.web_search" = true;
        };
      };
    in
      result.config.files ? ".config/kimchi/harness/settings.json"
  );

  # The Cast AI key is a runtime credential ({file|helper}); setting
  # apiKey.file must evaluate and must never become a static env var.
  module-kimchi-credential = mkTest "kimchi-credential" (
    let
      result = evalDevenv {
        ai.kimchi = {
          enable = true;
          apiKey.file = "/run/secrets/kimchi-key";
        };
      };
    in
      builtins.length result.config.packages
      == 1
      && result.config.env == {}
  );

  # Real-execution gate for the wrapProgram blocker (#1) + secret handling
  # (#3): build the wrapped package (over the tiny aiStubs.kimchi bin) with
  # a second env var plus a credential, and assert the wrapper sets static
  # env via --set and reads the key from its file at runtime (cat), never
  # baking the secret literal into the store. The old backslash-newline
  # separator made this build fail with exit 127 once >=2 args were present.
  module-kimchi-wrapper-builds = let
    result = evalHm {
      ai.kimchi = {
        enable = true;
        apiKey.file = "/run/secrets/kimchi-test";
        environmentVariables.KIMCHI_EXTRA = "yes";
      };
    };
    wrapped = builtins.head result.config.home.packages;
  in
    pkgs.runCommand "module-test-kimchi-wrapper-builds" {} ''
      bin=${wrapped}/bin/kimchi
      grep -q "KIMCHI_NO_UPDATE_CHECK" "$bin"
      grep -q "KIMCHI_EXTRA" "$bin"
      grep -q 'cat "/run/secrets/kimchi-test"' "$bin"
      echo PASS > "$out"
    '';

  # openmemory-mcp: the postgres+http serve daemon contributes an ExecStartPre
  # (settingsToPreStart) that pre-creates the dimensioned pgvector table — the
  # upstream HNSW-dimension bug workaround. Assert it fires ONLY for the postgres
  # metadata+vector backend in http mode (one script), and is empty for stdio
  # mode and for the default sqlite backend. Eval-only: `"${writeShellScript …}"`
  # yields the store-path string without building, so no IFD.
  module-openmemory-pgvector-prestart = let
    srv = mcpLib.loadServer "openmemory-mcp";
    mkPre = settings: mode:
      srv.settingsToPreStart pkgs (mcpLib.mkCfgShim {
        evaluatedSettings = mcpLib.evalSettings "openmemory-mcp" settings;
        port = 19758;
        host = "127.0.0.1";
      })
      mode;
    pgSettings = {
      metadataBackend.postgres = {db = "test";};
      vectorBackend.postgres = {};
      vecDim = 768;
    };
  in
    mkTest "openmemory-pgvector-prestart" (
      (srv ? settingsToPreStart)
      && builtins.length (mkPre pgSettings "http") == 1
      && mkPre pgSettings "stdio" == []
      && mkPre {} "http" == []
    );
}

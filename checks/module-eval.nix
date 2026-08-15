# End-to-end module eval tests. Each test evaluates the full HM module
# (sharedOptions + every package's modules/homeManager) against a
# synthetic config and asserts the resulting option tree + config.
# cspell:ignore batchmode
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
  # The runtime registry, shared with lib/ai/sharedOptions.nix and
  # checks/options-doc.nix. Importing it rather than restating the five names
  # is what makes the tests below GROW when a sixth runtime lands: a hardcoded
  # list would keep passing while silently not covering the newcomer.
  harnessNames = import ./../lib/ai/runtimes.nix;
  codexExtracted = builtins.fromJSON (builtins.readFile ../overlays/chatgpt-codex-extracted.json);
  tomlFormat = pkgs.formats.toml {};
  # Generic idempotent-flag helper shared with mkKiro's wrapper (lib/idempotentFlags.nix).
  idempotentFlags = import ./../lib/idempotentFlags.nix {inherit lib;};
  # Kiro mcp-secret preprocessor + the rendered mcp.json body the module
  # feeds into its activation/enterShell writer (mkMcpJsonScript). Tests
  # assert placeholder content via `renderedMcpJson` and template-store-
  # path parity between the two backends.
  inherit (import ./../packages/kiro-cli/lib/mcpSecrets.nix {inherit lib;}) renderKiroSecrets;
  # Local credential-injecting reverse proxy (lib/ai/mcpProxy.nix).
  mcpProxyLib = import ./../lib/ai/mcpProxy.nix {inherit lib pkgs;};
  # Exercises all three header shapes the renderer must handle: a
  # credential WITH a prefix, a credential without one, and a plain
  # literal string that is not a secret at all — plus a credential url.
  #
  # Deliberately generic. A fixture copied from a real deployment
  # documents that deployment's topology in a public repository, and this
  # one only needs the SHAPES.
  proxySampleServer = {
    type = "http";
    url.file = "/run/secrets/upstream-url";
    timeout = 300000;
    proxy = {
      enable = true;
      host = "127.0.0.1";
      port = 9501;
      headers = {
        "X-Api-Key" = {
          file = "/run/secrets/api-key";
          prefix = "Bearer ";
        };
        "X-Route" = "primary";
        "X-Service-Token".file = "/run/secrets/service-token";
        # Null is a DELETION — the client sent it, the upstream must not
        # see it. Included in the shared fixture so every Caddyfile
        # assertion below exercises the third value shape.
        "X-Drop-Me" = null;
      };
    };
  };
  renderedMcpJson = servers:
    builtins.toJSON {
      mcpServers = lib.mapAttrs (name: mcpLib.renderServer pkgs name) (renderKiroSecrets servers).servers;
    };
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
      systemd.user = {
        paths = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
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
      # Home-manager provides these XDG paths in a real eval. Semble uses
      # cacheHome for its Codex sandbox grant; living-workflow uses stateHome
      # for its generated skill.
      xdg = {
        cacheHome = lib.mkOption {
          type = lib.types.str;
          default = "/home/test/.cache";
        };
        configHome = lib.mkOption {
          type = lib.types.str;
          default = "/home/test/.config";
        };
        stateHome = lib.mkOption {
          type = lib.types.str;
          default = "/home/test/.local/state";
        };
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
      # Real devenv exposes this at EVAL time — `devenv eval devenv.state`
      # returns an absolute path — which is what lets packages/glab derive
      # a project-local configDir with no runtime shell expansion. Same
      # stub shape checks/claude-devenv-hooks-real-type.nix uses for
      # devenv.root.
      devenv = {
        root = lib.mkOption {
          type = lib.types.str;
          default = "/tmp/devenv-root";
        };
        state = lib.mkOption {
          type = lib.types.str;
          default = "/tmp/devenv-state";
        };
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
      chatgpt-codex = pkgs.ai.chatgpt-codex or pkgs.hello;
      claude-code = pkgs.ai.claude-code or pkgs.hello;
      # Tiny `bin/copilot` stub, same reasoning as kimchi below plus one more:
      # the real copilot-cli is a large UNFREE binary, and the wrapper-content
      # test should not drag it into every `nix flake check`. No test asserts
      # the underlying package identity — only the `copilot-cli-wrapped` name.
      copilot-cli = pkgs.writeShellScriptBin "copilot" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        exec true
      '';
      # Force a tiny `bin/kimchi` stub so the HM wrapper build test is cheap
      # and the wrapProgram target exists (hello has no bin/kimchi).
      kimchi = pkgs.writeShellScriptBin "kimchi" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        exec true
      '';
      kiro-cli = pkgs.ai.kiro-cli or pkgs.hello;
      semble = pkgs.ai.semble or pkgs.hello;
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
        ./../packages/chatgpt-codex/modules/homeManager
        ./../packages/claude-code/modules/homeManager
        ./../packages/copilot-cli/modules/homeManager
        ./../packages/glab/modules/homeManager
        ./../packages/kimchi/modules/homeManager
        ./../packages/kiro-cli/modules/homeManager
        ./../packages/living-workflow/modules/homeManager
        ./../packages/mcp-services/modules/homeManager
        ./../packages/semble/modules/homeManager
        ./../packages/stacked-workflows/modules/homeManager
        hmStubs
        {inherit config;}
      ];
    };

  evalDevenvWithSpecialArgs = extraSpecialArgs: config:
    lib.evalModules {
      specialArgs =
        {
          lib = hmLib;
          pkgs = pkgs // {ai = pkgs.ai or {};};
        }
        // extraSpecialArgs;
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/chatgpt-codex/modules/devenv
        ./../packages/claude-code/modules/devenv
        ./../packages/copilot-cli/modules/devenv
        ./../packages/glab/modules/devenv
        ./../packages/kimchi/modules/devenv
        ./../packages/kiro-cli/modules/devenv
        ./../packages/living-workflow/modules/devenv
        ./../packages/semble/modules/devenv
        ./../packages/stacked-workflows/modules/devenv
        devenvStubs
        {inherit config;}
      ];
    };
  evalDevenv = evalDevenvWithSpecialArgs {};
  # The deterministic root tests assert paths only their injected resolver can
  # produce, so losing this specialArgs-only seam fails loudly instead of
  # silently measuring production builtins.getEnv behavior.
  evalDevenvWithGetEnv = codexGetEnv: evalDevenvWithSpecialArgs {inherit codexGetEnv;};

  # Codex HM settings are embedded as one-line JSON in the reconciliation
  # activation script rather than exposed as a home.file source. Keeping this
  # extractor in the eval harness lets the semantic parity tests continue to
  # compare the exact desired value without weakening production ownership back
  # to an immutable store symlink.
  hmCodexSettings = evaluated: let
    script = evaluated.config.home.activation.codexSettingsReconcile.text;
    beforeClosingMarker = lib.head (lib.splitString "\nNAT_TOML_SETTINGS_EOF\n" script);
    settingsJson = lib.last (lib.splitString "\n" beforeClosingMarker);
  in
    builtins.fromJSON (builtins.unsafeDiscardStringContext settingsJson);

  codexSettingsActivation = config:
    (evalHm config).config.home.activation.codexSettingsReconcile.text;

  # Helpers for the rollout-unlock tests. They exist to keep `lib.head` off an
  # unguarded filtered list: if the wrapper were renamed or dropped, `head`
  # throws an eval error, which surfaces as an infrastructure failure with a
  # stack trace rather than as this test failing. Worse, a comparison between
  # two silently-wrong singletons can pass VACUOUSLY. Asserting the match count
  # as part of the returned boolean fixes both.
  kiroWrappedDrvs = packages:
    map (p: p.drvPath) (lib.filter (p: (p.name or "") == "kiro-cli-wrapped") packages);

  # Exactly one wrapper on each side, and they must DIFFER (the unlock forked).
  soleFork = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a != builtins.head b;

  # Exactly one wrapper on each side, and they must MATCH (dedupe collapsed).
  soleSame = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a == builtins.head b;

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

  # Realize a wrapper the MODULE produced and read the shipped script.
  #
  # This is the WIRING level: it proves the module fed the right value into the
  # wrapper. Argv SEMANTICS — that the `@` prefix is present, that a root var
  # still expands at launch rather than at build, that a value survives as a
  # single argv token — are owned by the two run-the-wrapper checks
  # (checks/copilot-wrapper-argv.nix, checks/kiro-wrapper-argv.nix), which
  # EXECUTE the wrapper against an argv-printing stub. A grep cannot prove any
  # of those three: a builder-frozen `/homeless-shelter/...` and a live
  # `''${HOME}/...` are equally "present". Do not re-assert them here.
  #
  # `/homeless-shelter` is rejected on every use as the universal canary for a
  # runtime variable the BUILDER expanded — the defect class that shipped twice
  # in the copilot wrapper, once per backend.
  mkWrapperGrepTest = {
    name,
    package,
    bin,
    needles,
    # Strings that must NOT appear. A presence-only assertion cannot
    # distinguish "the winning value is baked in" from "both values are",
    # which is exactly what a precedence test has to prove.
    absentNeedles ? [],
  }:
    pkgs.runCommand "module-test-${name}" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      fail() {
        echo "FAIL: ${name}: $1" >&2
        exit 1
      }
      w=${package}/bin/${bin}
      [ -f "$w" ] || fail "no wrapper produced at $w"
      ${lib.concatMapStringsSep "\n" (needle: ''
          grep -qF -- ${lib.escapeShellArg needle} "$w" \
            || fail ${lib.escapeShellArg "wrapper does not carry: ${needle}"}
        '')
        needles}
      ${lib.concatMapStringsSep "\n" (needle: ''
          if grep -qF -- ${lib.escapeShellArg needle} "$w"; then
            fail ${lib.escapeShellArg "wrapper unexpectedly carries: ${needle}"}
          fi
        '')
        absentNeedles}
      if grep -qF -- '/homeless-shelter' "$w"; then
        fail "builder HOME leaked into the shipped wrapper"
      fi
      echo PASS > "$out"
    '';

  # The relative path a module actually rendered mcp-config.json to, read back
  # out of the module's own output. Wiring tests derive their expected flag
  # value from this rather than hardcoding it, so a `configDir` change moves
  # both ends together and only a genuine DIVERGENCE between "where the file is
  # written" and "where the flag points" can fail.
  mcpConfigKeyOf = name: files: let
    hits = lib.filter (lib.hasSuffix "/mcp-config.json") (lib.attrNames files);
  in
    if lib.length hits == 1
    then lib.head hits
    else throw "module-test-${name}: expected exactly one rendered mcp-config.json, found ${toString (lib.length hits)}";

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
  # Kiro HOOKS ride the same materializer (copy-only; v3 drops symlinked
  # hooks), so they get the same accessor trio against the hooks slug.
  hmHookPruneScript = ev: (ev.config.home.activation."materialize-kiro-hooks-prune" or {}).text or "";
  hmHookWriteScript = ev: (ev.config.home.activation."materialize-kiro-hooks-write" or {}).text or "";
  dvHookTaskExec = ev: ((ev.config.tasks or {})."ai:kiro:materialize-hooks" or {}).exec or "";
  # `lib.hasInfix` compiles its argument into a `builtins.match` regex, so a
  # needle containing `*` or `.` — which every glob does — silently matches
  # strings it should not (`"/*.json"` matches any `".json"`). `splitString`
  # escapes its separator, so this is a true literal search. Use it whenever
  # the needle is shell syntax rather than prose.
  hasLiteral = needle: hay: builtins.length (lib.splitString needle hay) > 1;
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

  # ── built-in Claude hook helpers ─────────────────────────────────
  # Every built-in hook's handler command is a /nix/store path, so match on the
  # derivation name rather than on an exact string.
  handlerCommands = blocks:
    lib.concatMap (b: map (h: h.command or "") (b.hooks or [])) blocks;
  hasClampHook = blocks:
    builtins.any (lib.hasInfix "claude-delegation-clamp") (handlerCommands blocks);
  hasGuardHook = blocks:
    builtins.any (lib.hasInfix "claude-memory-collision-guard") (handlerCommands blocks);

  # ── The A1 backstop: no module in THIS repo may define a ROOT ai.* option ──
  #
  # THE RULE: a root `ai.*` option may be defined only by the module that
  # DECLARES it. Every other module here writes `ai.<runtime>.<option>`; the
  # root level belongs to consumers.
  #
  # Root options are ADDITIVE and cannot be retracted per runtime. Once
  # per-runtime negation ships, a contribution this repo made at the root level
  # makes a consumer's negation evaluate perfectly cleanly and do nothing — no
  # error, no warning, and no visible difference except the feature they turned
  # off still being on. That silence is why this is enforced, not reviewed for.
  #
  # ── Why PROVENANCE and not a source scan ──
  #
  # The design record (plan §A1) specified a regex scan over `lib/**` and
  # `packages/*/modules/**`, and rejected provenance in one line: "an inline
  # module reports `<unknown-file>`, indistinguishable from a consumer's inline
  # config". True, and it points the WRONG WAY — `<unknown-file>` IS the
  # consumer, and the consumer is exactly who may write root options.
  #
  # A scan was built first and measured to miss whole classes of write, among
  # them shapes this repo itself uses: `config.ai.<pool> = …`; a value moved to
  # the next line, which is what alejandra emits for long assignments; and the
  # interpolated `ai.<runtime>.<pool>` form used by `mkBackendTransform.nix` and
  # `packages/semble/modules/common.nix`. Dynamic construction (`lib.genAttrs`,
  # `builtins.listToAttrs`) is UNDECIDABLE in a regex — a permanent hole rather
  # than a fixable bug. All of it is caught here for free, because this runs
  # AFTER evaluation: by then there is no syntax left, only definitions and the
  # files they came from.
  #
  # ── Why "not the declaring module" rather than a file allowlist ──
  #
  # An option's DEFAULT is itself a definition, attributed to the file that
  # DECLARED the option. Measured: an option declared in a file and never
  # written still reports one definition, blamed on that file. A hardcoded
  # allowlist of `sharedOptions.nix` therefore did not exempt what its comment
  # claimed — it masked the synthetic default-definitions, and it would have
  # reported a root option declared in any OTHER file as a violation purely for
  # having a default.
  #
  # Comparing against `opt.declarations` fixes both. It exempts the declaring
  # module — which is what legitimately defines the `ai.rulesDir` L1→L2 reshape,
  # since `ai.rulesDir` is itself a ROOT option with nowhere else to expand to —
  # and needs no maintenance when options move. Consequence to accept: a module
  # that both declares and defines a root option is exempt. Declaring one
  # outside `sharedOptions.nix` would already fail `checks/options-doc.nix`'s
  # cross-backend parity gate, so that is not a quiet path.
  #
  # ── The real cost: reachability ──
  #
  # A definition suppressed by `mkIf false` is DROPPED from the definition list
  # entirely. Measured — it is NOT relabelled to `<unknown-file>`; that entry,
  # when it appears, is the option's default. So this sees only code paths the
  # evaluated config reaches, which the deleted text scan did not depend on.
  #
  # `rootPoolProbeConfig` is therefore load-bearing rather than a convenience:
  # every per-CLI config callback is wrapped in `lib.mkIf cfg.enable`
  # (`lib/ai/app/mkBackendTransform.nix`), so without the runtime enables this
  # guard would evaluate a tree in which the ENTIRE fanout body contributes
  # nothing — the largest and likeliest home for a root write, invisible. The
  # runtimes come from the shared registry so a sixth is covered the day it
  # lands; the skill packages are named because they gate on their own flags.
  #
  # Verified by mutation, not by reading: a root write gated on
  # `config.ai.claude.enable` is reported with these enables and vanishes
  # without them.
  #
  # Second, smaller cost: `definitionsWithLocations` is post-`filterOverrides`,
  # so if some definition wins on PRIORITY (a `mkForce` anywhere) the losing
  # definitions — possibly including a repo root write — drop off the list. That
  # cannot produce the silent-negation bug this guard exists to prevent, since a
  # filtered-out definition contributes nothing to the value either; it only
  # means the reported violation LIST can be incomplete when two definitions of
  # one option disagree on priority.
  #
  # This check is a stopgap. §A1's own preferred answer is a factory that
  # generates both levels from one spec and makes the fanout structural; when
  # that lands, a root write can no longer be expressed and this can go.
  rootPoolSrcRoot = toString ./..;

  rootPoolProbeConfig = {
    ai = lib.genAttrs harnessNames (_: {enable = true;});
    living-workflow.enable = true;
    stacked-workflows.enable = true;
  };

  rootPoolViolations = evaluated: let
    isOurs = file: lib.hasPrefix rootPoolSrcRoot (toString file);
    # `options.ai` holds root options alongside per-runtime GROUPS (ai.claude
    # and friends), which are plain attrsets rather than options. `isOption`
    # selects exactly the root surface, and with NO hardcoded pool list — a pool
    # added to sharedOptions.nix is covered the day it is declared, which the
    # scan's hand-maintained alternation was not.
    #
    # Limitation, stated because it is otherwise invisible: this walks ONE
    # level. A root option nested under a non-option attrset would not be seen.
    # None exists today — every member of `options.ai` is either an option or a
    # per-runtime group.
    rootOptions = lib.filterAttrs (_: lib.isOption) evaluated.options.ai;
    foreignDefs = name: opt: let
      declaredIn = map toString (opt.declarations or []);
      foreign = d: isOurs d.file && !(lib.elem (toString d.file) declaredIn);
    in
      map (d: "ai.${name} <- ${toString d.file}")
      (lib.filter foreign (opt.definitionsWithLocations or []));
  in
    lib.concatLists (lib.mapAttrsToList foreignDefs rootOptions);

  # Throws with the offending option/file pairs rather than a bare "FAIL",
  # because the whole value of this check is telling the next author WHERE. The
  # diagnostic names the module that CONTRIBUTED the definition, which for a
  # factory-produced module is the caller that imported it, not the factory.
  rootPoolClean = backend: evaluated: let
    violations = rootPoolViolations evaluated;
  in
    violations
    == []
    || throw ''
      Root ai.* option defined by a module in this repo (${backend}):

        ${builtins.concatStringsSep "\n  " violations}

      Root options are ADDITIVE and cannot be retracted per runtime, so this
      makes a consumer's per-runtime negation evaluate clean and silently do
      nothing. Write ai.<runtime>.<option> instead, gated on
      `lib.hasAttrByPath ["ai" name "<option>"] options`.
    '';
in {
  # ── Kiro launcher wrapper: flag injection ────────────────────────
  # Launcher-GLOBAL options are PREPENDED — appended after a subcommand,
  # clap parses them against that subcommand and rejects them
  # ("unexpected argument"). Injection stays idempotent because they
  # abort on repetition. Prepending walks the list in reverse, since
  # each `set --` pushes onto the front, so a two-flag list must emit
  # the LAST one first to land in the written order.
  #
  # These exercise `lib/idempotentFlags.nix` generically, with `--tui`
  # and `--v3` as sample flags — the two-flag ordering property is the
  # point. The kiro wrapper itself injects only `--v3`; `ai.kiro.tui`
  # was removed.
  #
  # These pin the SHAPE of the generated bash. What that bash does to a
  # real argv — including which SIDE of the subcommand a flag lands on
  # — is checks/kiro-wrapper-argv.nix, which runs the wrapper.
  module-kiro-wrapper-prepend-both = mkTest "kiro-wrapper-prepend-both" (
    let
      b = idempotentFlags.idempotentFlagBlock {
        flags = ["--tui" "--v3"];
        position = "prepend";
      };
      tuiLine = ''if [ "$nat_seen_tui" = 0 ]; then set -- --tui "$@"; fi'';
      v3Line = ''if [ "$nat_seen_v3" = 0 ]; then set -- --v3 "$@"; fi'';
    in
      lib.hasInfix "nat_seen_tui=0" b
      && lib.hasInfix "nat_seen_v3=0" b
      && lib.hasInfix "--tui) nat_seen_tui=1 ;;" b
      && lib.hasInfix "--v3) nat_seen_v3=1 ;;" b
      && lib.hasInfix tuiLine b
      && lib.hasInfix v3Line b
      # reverse emission order is what makes the result `--tui --v3 …`
      && (lib.length (lib.splitString v3Line (lib.head (lib.splitString tuiLine b))) == 2)
  );

  # The append form is still available for a genuinely per-subcommand
  # option, and must NOT be reachable by accident: `position` has no
  # default, since picking the wrong one is the exact bug this guards.
  module-kiro-wrapper-append-form = mkTest "kiro-wrapper-append-form" (
    let
      b = idempotentFlags.idempotentFlagBlock {
        flags = ["--v3"];
        position = "append";
      };
    in
      lib.hasInfix ''if [ "$nat_seen_v3" = 0 ]; then set -- "$@" --v3; fi'' b
      && !(lib.hasInfix "tui" b)
  );

  module-kiro-wrapper-rejects-bad-position =
    mkTest "kiro-wrapper-rejects-bad-position" (!(builtins.tryEval (idempotentFlags.idempotentFlagBlock {
      flags = ["--v3"];
      position = "middle";
    }))
    .success);

  module-kiro-wrapper-idempotent-none = mkTest "kiro-wrapper-idempotent-none" (
    idempotentFlags.idempotentFlagBlock {
      flags = [];
      position = "prepend";
    }
    == ""
  );

  # ── Kiro launcher wrapper: subcommand gating ─────────────────────
  # Used for the options that genuinely ARE per-subcommand: `--tui`
  # (meaningless outside a bare launch and `chat`) and the chat
  # binary's `--trust-tools`. The scan resolves the subcommand into
  # nat_sub; the value-flag arm keeps `--agent acp` from reading as the
  # acp subcommand; `--` parks on a sentinel no gate matches.
  module-kiro-wrapper-subcommand-scan = mkTest "kiro-wrapper-subcommand-scan" (
    let
      b = idempotentFlags.subcommandBlock ["--agent" "--resume-id"];
    in
      lib.hasInfix ''nat_sub=""'' b
      && lib.hasInfix "--agent|--resume-id) nat_skip=1 ;;" b
      && lib.hasInfix ''--) nat_sub="--"; break ;;'' b
      && lib.hasInfix "-*) ;;" b
      && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
  );

  # No value-taking options ⇒ no skip arm, but the scan still resolves
  # a subcommand (a wrapper with only boolean options still needs it).
  module-kiro-wrapper-subcommand-scan-boolean-only = mkTest "kiro-wrapper-subcommand-scan-boolean-only" (
    let
      b = idempotentFlags.subcommandBlock [];
    in
      !(lib.hasInfix "nat_skip=1 ;;" b)
      && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
  );

  # The gate wraps the injection in a `case` over the accepted set.
  # `bareInvocation` is the empty string, so a gate covering the bare
  # launch emits a `''`-quoted alternative ahead of the named ones.
  module-kiro-wrapper-gate-wraps-injection = mkTest "kiro-wrapper-gate-wraps-injection" (
    let
      b = idempotentFlags.gateOnSubcommand {
        subcommands = [idempotentFlags.bareInvocation "chat"];
        valueFlags = ["--agent"];
      } "INJECTED";
    in
      lib.hasInfix ''case "$nat_sub" in'' b
      && lib.hasInfix "  ''|chat)" b
      && lib.hasInfix "    INJECTED" b
      && lib.hasSuffix "esac" b
  );

  # Nothing to inject ⇒ no gate at all (an env-only wrapper must stay a
  # transparent exec, not grow a dead `case`).
  module-kiro-wrapper-gate-empty-injection = mkTest "kiro-wrapper-gate-empty-injection" (
    idempotentFlags.gateOnSubcommand {subcommands = ["chat"];} "" == ""
  );

  # An empty accepted set can never fire, which would silently drop the
  # injection rather than fail — so it throws instead.
  module-kiro-wrapper-gate-rejects-empty-set = mkTest "kiro-wrapper-gate-rejects-empty-set" (!(builtins.tryEval (idempotentFlags.gateOnSubcommand {subcommands = [];} "INJECTED")).success);

  module-claude-default-disabled = mkTest "claude-default-disabled" (
    !(evalHm {}).config.ai.claude.enable
    && !(evalDevenv {}).config.ai.claude.enable
  );

  # ── Codex package/factory enable vertical ───────────────────────
  module-codex-default-disabled = mkTest "codex-default-disabled" (
    let
      hm = evalHm {};
      devenv = evalDevenv {};
    in
      !hm.config.ai.codex.enable
      && !devenv.config.ai.codex.enable
      && hm.config.home.packages == []
      && devenv.config.packages == []
  );

  # The two backends legitimately install DIFFERENT derivations here, and the
  # asymmetry is the sandbox-safe Git SSH default rather than anything about
  # Codex. Home Manager states it in Git's own config, so nothing has to reach
  # Codex's process environment and the upstream package ships untouched.
  # devenv has no `programs.git`, so the same default rides Codex's launcher
  # wrapper — deliberately, because the alternative is exporting
  # `GIT_SSH_COMMAND` into the project shell and rewriting Git for the
  # developer's own session too. Net effect: enabling Codex on devenv always
  # produces a wrapper. The VALUE it carries is asserted by
  # `module-ai-git-ssh-default-follows-harnesses`; this one is about shape.
  module-codex-enabled-installs-package = mkTest "codex-enabled-installs-package" (
    let
      hm = evalHm {ai.codex.enable = true;};
      devenv = evalDevenv {ai.codex.enable = true;};
      expected = aiStubs.chatgpt-codex;
      devenvPackages = devenv.config.packages;
    in
      hm.config.home.packages
      == [expected]
      && builtins.length devenvPackages == 1
      && lib.hasSuffix "chatgpt-codex-wrapped" (
        builtins.baseNameOf (builtins.head devenvPackages)
      )
  );

  # ── A1 backstop: no repo module defines a ROOT ai.* option ──
  #
  # One per backend, because the pools are per-`evalModules`: an HM
  # contribution is invisible to the devenv evaluation and vice versa, so a
  # single-backend guard would miss half the tree.
  module-ai-no-root-pool-writes-hm = mkTest "ai-no-root-pool-writes-hm" (
    rootPoolClean "home-manager" (evalHm rootPoolProbeConfig)
  );

  module-ai-no-root-pool-writes-devenv = mkTest "ai-no-root-pool-writes-devenv" (
    rootPoolClean "devenv" (evalDevenv rootPoolProbeConfig)
  );

  # POSITIVE CONTROL. The two guards above pass by finding NOTHING, so a guard
  # that detected nothing at all would look identical to a clean tree. This
  # evaluates a fixture that really does write a root pool and requires the
  # guard to name it — and it goes through `rootPoolClean`, not just
  # `rootPoolViolations`, so the throw path is covered too rather than only the
  # detection path. Delete these three as a set or not at all.
  #
  # Scoped to `sharedOptions.nix` plus the fixture: that module declares every
  # root `ai.*` option, so it is the whole surface under test, and a two-module
  # evaluation cannot pass for an unrelated reason.
  module-ai-root-pool-guard-fires = mkTest "ai-root-pool-guard-fires" (
    let
      probe = lib.evalModules {
        specialArgs = {
          lib = hmLib;
          pkgs = pkgs // {ai = aiStubs;};
        };
        modules = [
          ./../lib/ai/sharedOptions.nix
          ./fixtures/root-pool-writer.nix
        ];
      };
      violations = rootPoolViolations probe;
      # The guard must name THIS option and THIS file — not merely return
      # something non-empty, which a constant would also satisfy.
      named =
        builtins.length violations
        == 1
        && lib.hasInfix "ai.skills" (builtins.head violations)
        && lib.hasInfix "root-pool-writer.nix" (builtins.head violations);
      # And `rootPoolClean` must actually throw on that input. `tryEval` cannot
      # catch a `throw` raised while building the message, so force it.
      threw = !(builtins.tryEval (rootPoolClean "probe" probe)).success;
    in
      named && threw
  );

  # The option-presence gate in `lib/ai/mkSkillPackageModule.nix` is what lets a
  # consumer import a skill package WITHOUT importing all five runtime modules.
  #
  # Read how this test fails, because it is not the assertion below. Writing an
  # undeclared option is an EVALUATION error, so deleting the gate does not make
  # the boolean false — it aborts the evaluation with "The option `ai.codex'
  # does not exist" (measured). The assertion only confirms the write landed on
  # the one runtime that IS declared; the gate's coverage comes from the
  # evaluation completing at all.
  #
  # Declaring exactly one runtime is what creates that sensitivity, and it is
  # why this cannot be folded into the full-tree tests: `evalHm`/`evalDevenv`
  # import every runtime, so every option exists there and an ungated write
  # would evaluate cleanly and pass unnoticed.
  module-skill-package-gates-on-option-presence = mkTest "skill-package-gates-on-option-presence" (
    let
      onlyClaude = lib.evalModules {
        specialArgs = {
          lib = hmLib;
          pkgs = pkgs // {ai = aiStubs;};
        };
        modules = [
          {
            options.ai.claude = {
              instructions = lib.mkOption {
                type = lib.types.listOf lib.types.attrs;
                default = [];
              };
              skills = lib.mkOption {
                type = lib.types.attrsOf lib.types.path;
                default = {};
              };
            };
          }
          (import ./../lib/ai/mkSkillPackageModule.nix {
            name = "probe-package";
            enableDescription = "presence-gate probe";
            skills = _: {probe-skill = ./fixtures;};
          })
          {probe-package.enable = true;}
        ];
      };
    in
      onlyClaude.config.ai.claude.skills ? probe-skill
  );

  module-ai-git-ssh-default-follows-harnesses = mkTest "ai-git-ssh-default-follows-harnesses" (
    let
      # devenv has no `programs.git`, so the workaround travels the INTERNAL
      # channel (`ai._sandboxSafeSshCommand`) and each factory merges it into
      # its launcher wrapper. It is deliberately neither a project-shell write
      # (which reached the developer's own git) nor a contribution into
      # `ai.<cli>.environmentVariables` (which is collision-checked, so a
      # module default there turns a consumer's own entry for the same key
      # into a hard eval error). Claude has no wrapper and uses settings.env.
      devenvChannel = name: let
        cfg = (evalDevenv (lib.setAttrByPath ["ai" name "enable"] true)).config;
      in
        if name == "claude"
        then cfg.ai.claude.settings.env.GIT_SSH_COMMAND
        else cfg.ai._sandboxSafeSshCommand;
      commands =
        lib.concatMap (name: [
          (evalHm (lib.setAttrByPath ["ai" name "enable"] true))
          .config
          .programs
          .git
          .settings
          .core
          .sshCommand
          (devenvChannel name)
        ])
        harnessNames;
      disabledHm = (evalHm {}).config;
      disabledDevenv = (evalDevenv {}).config;
      optedOutHm =
        (evalHm {
          ai.codex.enable = true;
          ai.gitSshConfigWorkaround = false;
        }).config;
      optedOutDevenv =
        (evalDevenv {
          ai.codex.enable = true;
          ai.gitSshConfigWorkaround = false;
        }).config;
      overriddenHm =
        (evalHm {
          ai.codex.enable = true;
          programs.git.settings.core.sshCommand = "custom-ssh";
        }).config;
      # REGRESSION GUARD: a consumer setting the shared pool key the module
      # also contributes must NOT be a collision error. It was, briefly —
      # the module wrote into `ai.<cli>.environmentVariables`, which is
      # compared by key presence and cannot see `mkDefault`.
      sharedPoolCollision =
        (evalDevenv {
          ai.codex.enable = true;
          ai.environmentVariables.GIT_SSH_COMMAND = "consumer-ssh";
        }).config;
    in
      builtins.all (lib.hasSuffix "/bin/ai-sandbox-safe-ssh") commands
      && !(disabledHm.programs.git.settings ? core)
      && disabledDevenv.ai._sandboxSafeSshCommand == null
      && !(optedOutHm.programs.git.settings ? core)
      && optedOutDevenv.ai._sandboxSafeSshCommand == null
      && overriddenHm.programs.git.settings.core.sshCommand == "custom-ssh"
      && builtins.all (a: a.assertion) sharedPoolCollision.assertions
  );

  module-ai-git-ssh-wrapper-is-noninteractive = let
    command = (evalDevenv {ai.codex.enable = true;}).config.ai._sandboxSafeSshCommand;
    sshConfig = pkgs.writeText "sandbox-ssh-config" ''
      Host *
        BatchMode no
    '';
  in
    pkgs.runCommand "module-test-ai-git-ssh-wrapper-is-noninteractive" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      mkdir -p home/.ssh
      ln -s ${sshConfig} home/.ssh/config
      HOME="$PWD/home" ${command} -G github.com > resolved
      ${pkgs.gnugrep}/bin/grep -Fqx 'batchmode yes' resolved || {
        echo "FAIL: expected OpenSSH to resolve 'batchmode yes'; got:" >&2
        ${pkgs.gnugrep}/bin/grep -F 'batchmode ' resolved >&2 || :
        exit 1
      }
      touch "$out"
    '';

  module-codex-default-sandbox-roots = mkTest "codex-default-sandbox-roots" (
    let
      settings = {
        ai.codex = {
          enable = true;
          settings.sandbox_mode = "workspace-write";
        };
      };
      hmRoots = (evalHm settings).config.ai.codex.settings.sandbox_workspace_write.writable_roots;
      rootsWithEnvironment = environment:
        (evalDevenvWithGetEnv (name: environment.${name} or "") settings).config.ai.codex.settings.sandbox_workspace_write.writable_roots;
      devenvHomeRoots = rootsWithEnvironment {HOME = "/home/test";};
      devenvXdgRoots = rootsWithEnvironment {
        HOME = "/home/ignored";
        XDG_CACHE_HOME = "/tmp/xdg-cache";
      };
    in
      hmRoots
      == ["/home/test/.cache/nix"]
      && devenvHomeRoots == ["/tmp/devenv-root/.git" "/home/test/.cache/nix"]
      && devenvXdgRoots == ["/tmp/devenv-root/.git" "/tmp/xdg-cache/nix"]
  );

  module-codex-default-getenv-needs-no-module-arg = mkTest "codex-default-getenv-needs-no-module-arg" (
    let
      roots =
        (evalDevenv {
          ai.codex = {
            enable = true;
            settings.sandbox_mode = "workspace-write";
          };
        }).config.ai.codex.settings.sandbox_workspace_write.writable_roots;
    in
      builtins.deepSeq roots (builtins.elem "/tmp/devenv-root/.git" roots)
  );

  module-codex-skills-disabled-emits-nothing = mkTest "codex-skills-disabled-emits-nothing" (
    let
      config.ai.codex.skills.example = ./fixtures/claude-skills/skill-a;
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      !(hm.config.home.file ? ".agents/skills/example")
      && !(devenv.config.files ? ".agents/skills/example/SKILL.md")
  );

  module-codex-skills-fanout = mkTest "codex-skills-fanout" (
    let
      config.ai = {
        codex = {
          enable = true;
          skills.local = ./fixtures/claude-skills/skill-b;
        };
        skills.shared = ./fixtures/claude-skills/skill-a;
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      hm.config.home.file.".agents/skills/local".source
      == ./fixtures/claude-skills/skill-b
      && hm.config.home.file.".agents/skills/local".recursive
      && hm.config.home.file.".agents/skills/shared".source
      == ./fixtures/claude-skills/skill-a
      && hm.config.home.file.".agents/skills/shared".recursive
      && devenv.config.files.".agents/skills/local/SKILL.md".source
      == ./fixtures/claude-skills/skill-b/SKILL.md
      && devenv.config.files.".agents/skills/shared/SKILL.md".source
      == ./fixtures/claude-skills/skill-a/SKILL.md
  );

  module-codex-skillsdir-fanout = mkTest "codex-skillsdir-fanout" (
    let
      config.ai.codex = {
        enable = true;
        skillsDir = ./fixtures/claude-skills;
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      hm.config.home.file ? ".agents/skills/skill-a"
      && hm.config.home.file ? ".agents/skills/skill-b"
      && devenv.config.files ? ".agents/skills/skill-a/SKILL.md"
      && devenv.config.files ? ".agents/skills/skill-b/SKILL.md"
  );

  module-codex-skill-collision-fails = mkTest "codex-skill-collision-fails" (
    let
      evaluated = evalHm {
        ai = {
          codex = {
            enable = true;
            skills.duplicate = ./fixtures/claude-skills/skill-b;
          };
          skills.duplicate = ./fixtures/claude-skills/skill-a;
        };
      };
    in
      builtins.any (assertion: !assertion.assertion && lib.hasInfix "skills 'duplicate'" assertion.message) evaluated.config.assertions
  );

  module-codex-empty-settings-emits-no-toml = mkTest "codex-empty-settings-emits-no-toml" (
    let
      hm = evalHm {ai.codex.enable = true;};
      devenv = evalDevenv {ai.codex.enable = true;};
    in
      !(hm.config.home.file ? ".codex/config.toml")
      && hmCodexSettings hm == {}
      && !(hm.config.home.file ? ".codex/hooks.json")
      && !(devenv.config.files ? ".codex/config.toml")
      && !(devenv.config.files ? ".codex/hooks.json")
  );

  # ── Beta permission model lockout ──────────────────────────────────────
  # A profile-materializer lifecycle test and a materializer collision test
  # lived here and drove `ai.codex.profiles` end to end. That option and the
  # `default_permissions`/`permissions` settings beside it are now locked out
  # (see the lockout comment in packages/chatgpt-codex/lib/mkCodex.nix), so
  # their runtime behavior is unreachable and these assert the lockout itself.
  # The profile name-shape and intra-layer sandbox-model tests below are kept:
  # they cover the surface that has to still be valid if this is ever undone.
  module-codex-profiles-locked-out = mkTest "codex-profiles-locked-out" (
    let
      config.ai.codex = {
        enable = true;
        profiles.review.model_reasoning_effort = "low";
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "ai.codex.profiles is locked out" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config) && rejects (evalDevenv config)
  );

  module-codex-default-permissions-locked-out = mkTest "codex-default-permissions-locked-out" (
    let
      config.ai.codex = {
        enable = true;
        settings.default_permissions = ":workspace";
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "ai.codex.settings.default_permissions is locked out" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config) && rejects (evalDevenv config)
  );

  module-codex-permissions-locked-out = mkTest "codex-permissions-locked-out" (
    let
      config.ai.codex = {
        enable = true;
        settings.permissions.project-edit.extends = ":workspace";
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "ai.codex.settings.permissions is locked out" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config) && rejects (evalDevenv config)
  );

  module-codex-profile-name-rejects-unsafe-stems = mkTest "codex-profile-name-rejects-unsafe-stems" (
    let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          profiles."../escape".model = "gpt-5.6-sol";
        };
      };
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "must start with a letter or number" assertion.message)
      evaluated.config.assertions
  );

  module-codex-profile-sandbox-model-conflict = mkTest "codex-profile-sandbox-model-conflict" (
    let
      config.ai.codex = {
        enable = true;
        profiles.mixed = {
          default_permissions = "project-edit";
          permissions.project-edit.extends = ":workspace";
          sandbox_mode = "read-only";
        };
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "ai.codex.profiles.mixed must use either" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config) && rejects (evalDevenv config)
  );

  module-codex-profile-settings-type-enforced = mkTest "codex-profile-settings-type-enforced" (
    let
      rejects = evaluator: let
        attempt = builtins.tryEval (let
          result = evaluator {
            ai.codex = {
              enable = true;
              profiles.review.model_reasoning_effort = "impossible";
            };
          };
        in
          builtins.deepSeq result.config.ai.codex.profiles true);
      in
        !attempt.success;
    in
      rejects evalHm && rejects evalDevenv
  );

  module-codex-profiles-hm-devenv-parity = mkTest "codex-profiles-hm-devenv-parity" (
    let
      config.ai.codex = {
        enable = true;
        profiles.deep-review = {
          model = "gpt-5.6-sol";
          model_reasoning_effort = "high";
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      profile = hm.config.home.file.".codex/deep-review.config.toml".source.value;
      # Emission parity is still proven while the option is locked out, so
      # re-enabling restores a TESTED path rather than an untested one. The
      # lockout must also be the ONLY thing blocking it — if a second assertion
      # starts failing here, the retained code has rotted behind the lock.
      failing = builtins.filter (assertion: !assertion.assertion) devenv.config.assertions;
    in
      profile
      == {
        model = "gpt-5.6-sol";
        model_reasoning_effort = "high";
      }
      && devenv.config.tasks ? "ai:codex:materialize-profiles"
      && builtins.length failing == 1
      && lib.hasInfix "ai.codex.profiles is locked out" (builtins.head failing).message
  );

  module-codex-mcp-lowering-parity = mkTest "codex-mcp-lowering-parity" (
    let
      config.ai = {
        codex.enable = true;
        mcpServers = {
          docs = {
            command = "/bin/docs";
            args = ["serve"];
            codex = {
              command = "must-not-clobber-base";
              defaultToolsApprovalMode = "prompt";
              disabledTools = ["delete"];
              enabled = true;
              required = true;
              startupTimeoutSec = 15;
              tools.search.approvalMode = "auto";
            };
          };
          remote = {
            url = "https://example.test/mcp";
            codex = {
              bearerTokenEnvVar = "MCP_TOKEN";
              envHttpHeaders.X-Tenant = "MCP_TENANT";
              toolTimeoutSec = 90;
            };
          };
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      expected = {
        docs = {
          args = ["serve"];
          command = "/bin/docs";
          default_tools_approval_mode = "prompt";
          disabled_tools = ["delete"];
          enabled = true;
          required = true;
          startup_timeout_sec = 15;
          tools.search.approval_mode = "auto";
        };
        remote = {
          bearer_token_env_var = "MCP_TOKEN";
          env_http_headers.X-Tenant = "MCP_TENANT";
          tool_timeout_sec = 90;
          url = "https://example.test/mcp";
        };
      };
    in
      (hmCodexSettings hm).mcp_servers
      == expected
      && devenv.config.files.".codex/config.toml".source.value.mcp_servers == expected
  );

  module-codex-mcp-freeform-rejects-non-toml = mkTest "codex-mcp-freeform-rejects-non-toml" (
    let
      hm = evalHm {
        ai.codex = {
          enable = true;
          mcpServers.docs = {
            command = "/bin/docs";
            codex.future = value: value;
          };
        };
      };
      evaluated = builtins.tryEval (hmCodexSettings hm);
    in
      !evaluated.success
  );

  module-codex-mcp-credential-wrapper-parity = mkTest "codex-mcp-credential-wrapper-parity" (
    let
      config.ai = {
        codex.enable = true;
        mcpServers.context7-mcp = {
          package = pkgs.hello;
          settings.credentials.file = "/run/secrets/context7-api-key";
        };
      };
      hmServer = (hmCodexSettings (evalHm config)).mcp_servers.context7-mcp;
      devenvServer = (evalDevenv config).config.files.".codex/config.toml".source.value.mcp_servers.context7-mcp;
      rendered = builtins.toJSON hmServer;
    in
      hmServer
      == devenvServer
      && lib.hasInfix "context7-mcp-env" hmServer.command
      && lib.take 2 hmServer.args == ["--transport" "stdio"]
      && !(lib.hasInfix "/run/secrets/context7-api-key" rendered)
      && !(hmServer ? type)
  );

  # Exercise every supported MCP lowering shape together: two HTTP services,
  # three typed package servers (including two credential wrappers), and one
  # raw stdio server must coexist in Codex's native table. Keep this rationale
  # self-contained; private implementation handoffs are intentionally
  # disposable and must never become the only explanation for a durable gate.
  module-codex-mcp-downstream-pool-compatible = mkTest "codex-mcp-downstream-pool-compatible" (
    let
      config.ai = {
        codex.enable = true;
        mcpServers = {
          context7-mcp = {
            package = pkgs.hello;
            settings.credentials.file = "/run/secrets/context7-api-key";
          };
          effect-mcp.url = "http://127.0.0.1:19760/mcp";
          git-mcp.package = pkgs.hello;
          github-mcp = {
            package = pkgs.hello;
            settings.credentials.file = "/run/secrets/github-token";
          };
          nixos-mcp.url = "http://127.0.0.1:19761/mcp";
          openmemory = {
            command = "/bin/openmemory";
            args = ["mcp"];
          };
        };
      };
      hmServers = (hmCodexSettings (evalHm config)).mcp_servers;
      devenvServers = (evalDevenv config).config.files.".codex/config.toml".source.value.mcp_servers;
    in
      hmServers
      == devenvServers
      && builtins.attrNames hmServers
      == [
        "context7-mcp"
        "effect-mcp"
        "git-mcp"
        "github-mcp"
        "nixos-mcp"
        "openmemory"
      ]
      && lib.hasInfix "context7-mcp-env" hmServers.context7-mcp.command
      && lib.hasInfix "github-mcp-env" hmServers.github-mcp.command
      && hmServers.effect-mcp.url == "http://127.0.0.1:19760/mcp"
      && hmServers.openmemory.command == "/bin/openmemory"
  );

  module-codex-mcp-native-table-collision-fails = mkTest "codex-mcp-native-table-collision-fails" (
    let
      evaluated = evalHm {
        ai = {
          codex = {
            enable = true;
            settings.mcp_servers.native.command = "native";
          };
          mcpServers.shared.command = "shared";
        };
      };
    in
      builtins.any (assertion: !assertion.assertion && lib.hasInfix "settings.mcp_servers" assertion.message) evaluated.config.assertions
  );

  module-aggregate-reasoning-effort-hm-devenv-parity = mkTest "aggregate-reasoning-effort-hm-devenv-parity" (
    let
      config.ai = {
        claude.enable = true;
        codex.enable = true;
        settings.reasoningEffort = "xhigh";
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      (hm.config.programs.claude-code.settings.effortLevel or null)
      == "xhigh"
      && ((hmCodexSettings hm).model_reasoning_effort or null) == "xhigh"
      && (devenv.config.files.".claude/settings.json".json.effortLevel or null) == "xhigh"
      && (devenv.config.files.".codex/config.toml".source.value.model_reasoning_effort or null) == "xhigh"
  );

  module-aggregate-reasoning-effort-native-overrides-win = mkTest "aggregate-reasoning-effort-native-overrides-win" (
    let
      config.ai = {
        claude = {
          enable = true;
          settings.effortLevel = "medium";
        };
        codex = {
          enable = true;
          settings.model_reasoning_effort = null;
        };
        settings.reasoningEffort = "high";
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      (hm.config.programs.claude-code.settings.effortLevel or null)
      == "medium"
      && !(hm.config.home.file ? ".codex/config.toml")
      && (devenv.config.files.".claude/settings.json".json.effortLevel or null) == "medium"
      && !(devenv.config.files ? ".codex/config.toml")
  );

  module-codex-settings-rendering-parity = mkTest "codex-settings-rendering-parity" (
    let
      config.ai.codex = {
        enable = true;
        settings = {
          features = {
            memories = true;
            speculative_future_flag = false;
          };
          model = "custom-provider/model";
          model_reasoning_effort = "ultra";
          model_verbosity = "low";
          personality = "pragmatic";
          web_search = "indexed";
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      expected = {
        features = {
          memories = true;
          speculative_future_flag = false;
        };
        model = "custom-provider/model";
        model_reasoning_effort = "ultra";
        model_verbosity = "low";
        personality = "pragmatic";
        web_search = "indexed";
      };
      devenvSource = devenv.config.files.".codex/config.toml".source;
    in
      hmCodexSettings hm
      == expected
      && devenvSource.value == expected
  );

  # This is a real activation lifecycle test, not merely an eval-shape check.
  # Codex persists ad-hoc trust and native feature/MCP edits in user
  # config.toml, so regressions here otherwise surface only when the TUI tries
  # config/batchWrite against an immutable Nix store symlink.
  module-codex-settings-reconciliation = let
    activationV1 = codexSettingsActivation {
      ai.codex = {
        enable = true;
        settings = {
          features.memories = true;
          future_array = [
            {
              enabled = true;
              name = "one";
            }
          ];
          mcp_servers.managed.command = "/bin/managed-v1";
          model = "nix-model-v1";
          shape = "scalar-v1";
        };
      };
    };
    activationV2 = codexSettingsActivation {
      ai.codex = {
        enable = true;
        settings = {
          model = "nix-model-v2";
          sandbox_mode = "read-only";
          shape.child = "table-v2";
        };
      };
    };
    activationEmpty = codexSettingsActivation {ai.codex.enable = true;};
    activationMalformed = codexSettingsActivation {
      ai.codex = {
        configDir = ".codex-malformed";
        enable = true;
        settings.model = "must-not-land";
      };
    };
    activationBadManifest = codexSettingsActivation {
      ai.codex = {
        configDir = ".codex-bad-manifest";
        enable = true;
        settings.model = "manifest-guard";
      };
    };
  in
    pkgs.runCommand "module-test-codex-settings-reconciliation" {} ''
      export HOME="$PWD/home"
      export XDG_STATE_HOME="$PWD/state"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex"

      # Model the old HM delivery exactly: config.toml is a read-only symlink
      # into immutable content. The first reconciliation must replace the link
      # itself, never follow it and attempt to mutate its target.
      ${pkgs.coreutils}/bin/cat > static-config.toml <<'EOF'
      # native comment survives
      model = "runtime-model"

      [features]
      native_runtime = true

      [projects."/home/test/ad-hoc"]
      trust_level = "trusted"
      EOF
      ${pkgs.coreutils}/bin/chmod 444 static-config.toml
      ${pkgs.coreutils}/bin/ln -s "$PWD/static-config.toml" "$HOME/.codex/config.toml"

      ${activationV1}

      test -f "$HOME/.codex/config.toml"
      test ! -L "$HOME/.codex/config.toml"
      test "$(${pkgs.coreutils}/bin/stat -c %a "$HOME/.codex/config.toml")" = 600
      ${pkgs.gnugrep}/bin/grep -Fq '# native comment survives' "$HOME/.codex/config.toml"
      ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
      import sys
      import tomllib

      with open(sys.argv[1], "rb") as handle:
          config = tomllib.load(handle)

      assert config["future_array"] == [{"enabled": True, "name": "one"}]
      assert config["shape"] == "scalar-v1"
      PY

      # Simulate native writers after activation. These siblings share tables
      # with Nix-owned leaves and therefore catch a too-coarse table manifest.
      ${pkgs.coreutils}/bin/cat >> "$HOME/.codex/config.toml" <<'EOF'

      [mcp_servers.native]
      command = "/bin/native"
      EOF

      ${activationV2}

      ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
      import sys
      import tomllib

      with open(sys.argv[1], "rb") as handle:
          config = tomllib.load(handle)

      assert config["model"] == "nix-model-v2"
      assert config["sandbox_mode"] == "read-only"
      assert config["projects"]["/home/test/ad-hoc"]["trust_level"] == "trusted"
      assert config["features"] == {"native_runtime": True}
      assert "future_array" not in config
      assert config["mcp_servers"] == {"native": {"command": "/bin/native"}}
      assert config["shape"] == {"child": "table-v2"}
      PY

      manifest="$(${pkgs.findutils}/bin/find "$XDG_STATE_HOME" -name '*.json' -type f -print)"
      test -n "$manifest"
      test "$(${pkgs.coreutils}/bin/stat -c %a "$manifest")" = 600
      test "$(${pkgs.coreutils}/bin/stat -c %a "$(${pkgs.coreutils}/bin/dirname "$manifest")")" = 700

      # Identical activation is byte- and metadata-idempotent. Pinning mtimes
      # before the second run detects an implementation that rewrites equal
      # content through a fresh temp file on every Home Manager activation.
      ${pkgs.coreutils}/bin/touch -d @1000000000 "$HOME/.codex/config.toml" "$manifest"
      config_mtime="$(${pkgs.coreutils}/bin/stat -c %Y "$HOME/.codex/config.toml")"
      manifest_mtime="$(${pkgs.coreutils}/bin/stat -c %Y "$manifest")"
      ${activationV2}
      test "$(${pkgs.coreutils}/bin/stat -c %Y "$HOME/.codex/config.toml")" = "$config_mtime"
      test "$(${pkgs.coreutils}/bin/stat -c %Y "$manifest")" = "$manifest_mtime"

      # Empty settings still run once to retire prior Nix leaves. Native state
      # remains and the now-empty ownership manifest disappears.
      ${activationEmpty}
      ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
      import sys
      import tomllib

      with open(sys.argv[1], "rb") as handle:
          config = tomllib.load(handle)

      assert "model" not in config
      assert "sandbox_mode" not in config
      assert "shape" not in config
      assert config["projects"]["/home/test/ad-hoc"]["trust_level"] == "trusted"
      assert config["features"] == {"native_runtime": True}
      assert config["mcp_servers"] == {"native": {"command": "/bin/native"}}
      PY
      test ! -e "$manifest"

      # With no prior ownership ledger, empty desired settings are a true no-op
      # and must not create or parse an externally managed config.
      export HOME="$PWD/empty-home"
      export XDG_STATE_HOME="$PWD/empty-state"
      ${activationEmpty}
      test ! -e "$HOME/.codex/config.toml"
      test ! -e "$XDG_STATE_HOME"

      # Malformed native TOML aborts before either config or ownership state is
      # changed. Silent replacement would destroy exactly the state this path
      # exists to preserve.
      export HOME="$PWD/malformed-home"
      export XDG_STATE_HOME="$PWD/malformed-state"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex-malformed"
      printf '%s\n' '[broken' > "$HOME/.codex-malformed/config.toml"
      before="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-malformed/config.toml")"
      if ${activationMalformed}
      then
        echo "malformed TOML reconciliation unexpectedly succeeded" >&2
        false
      fi
      after="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-malformed/config.toml")"
      test "$before" = "$after"
      test ! -e "$XDG_STATE_HOME"

      # The ownership ledger is authority for deletion, so corruption there is
      # also fail-closed. Guessing or discarding it could preserve stale Nix
      # policy or misclassify a native key as safe to remove.
      export HOME="$PWD/bad-manifest-home"
      export XDG_STATE_HOME="$PWD/bad-manifest-state"
      ${activationBadManifest}
      bad_manifest="$(${pkgs.findutils}/bin/find "$XDG_STATE_HOME" -name '*.json' -type f -print)"
      printf '%s\n' '{' > "$bad_manifest"
      before="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-bad-manifest/config.toml")"
      if ${activationBadManifest}
      then
        echo "malformed ownership manifest unexpectedly succeeded" >&2
        false
      fi
      after="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-bad-manifest/config.toml")"
      test "$before" = "$after"

      touch "$out"
    '';

  module-codex-security-settings-parity = mkTest "codex-security-settings-parity" (
    let
      config.ai.codex = {
        enable = true;
        settings = {
          allow_login_shell = false;
          approval_policy.granular = {
            mcp_elicitations = true;
            request_permissions = false;
            rules = true;
            sandbox_approval = true;
            skill_approval = false;
          };
          approvals_reviewer = "user";
          sandbox_mode = "workspace-write";
          sandbox_workspace_write = {
            exclude_slash_tmp = true;
            exclude_tmpdir_env_var = true;
            network_access = false;
            writable_roots = ["/var/lib/project-cache"];
          };
        };
      };
      hmSettings = hmCodexSettings (evalHm config);
      devenvSettings = (evalDevenv config).config.files.".codex/config.toml".source.value;
      withoutBackendRoots = settings:
        settings
        // {
          sandbox_workspace_write = removeAttrs settings.sandbox_workspace_write ["writable_roots"];
        };
    in
      withoutBackendRoots hmSettings
      == withoutBackendRoots devenvSettings
      && hmSettings.approval_policy.granular.rules
      && !hmSettings.approval_policy.granular.request_permissions
      && hmSettings.sandbox_mode == "workspace-write"
      && builtins.all
      (root: builtins.elem root hmSettings.sandbox_workspace_write.writable_roots)
      ["/var/lib/project-cache" "/home/test/.cache/nix"]
      && builtins.all
      (root: builtins.elem root devenvSettings.sandbox_workspace_write.writable_roots)
      ["/var/lib/project-cache" "/tmp/devenv-root/.git"]
  );

  module-codex-security-toml-syntax = let
    evaluated = evalHm {
      ai.codex = {
        enable = true;
        settings = {
          approval_policy.granular = {
            request_permissions = false;
            sandbox_approval = true;
          };
          projects."/home/test/project".trust_level = "trusted";
          sandbox_mode = "workspace-write";
          sandbox_workspace_write.network_access = false;
        };
      };
    };
    source = tomlFormat.generate "codex-security-settings.toml" (hmCodexSettings evaluated);
  in
    pkgs.runCommand "module-test-codex-security-toml-syntax" {} ''
      ${pkgs.gnugrep}/bin/grep -Fqx '[approval_policy.granular]' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'request_permissions = false' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '[projects."/home/test/project"]' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'trust_level = "trusted"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '[sandbox_workspace_write]' ${source}
      touch "$out"
    '';

  module-codex-security-models-do-not-compose = mkTest "codex-security-models-do-not-compose" (
    let
      check = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "default_permissions/permissions" assertion.message)
        evaluated.config.assertions;
      config.ai.codex = {
        enable = true;
        settings = {
          default_permissions = ":workspace";
          sandbox_mode = "workspace-write";
        };
      };
    in
      check (evalHm config)
      && check (evalDevenv config)
  );

  module-codex-security-empty-profile-model-does-not-conflict = mkTest "codex-security-empty-profile-model-does-not-conflict" (
    let
      config.ai.codex = {
        enable = true;
        settings = {
          permissions = {};
          sandbox_mode = "read-only";
        };
      };
      assertionsPass = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
    in
      assertionsPass (evalHm config)
      && assertionsPass (evalDevenv config)
  );

  module-codex-permission-profiles-parity = mkTest "codex-permission-profiles-parity" (
    let
      config.ai.codex = {
        enable = true;
        settings = {
          default_permissions = "project-edit";
          permissions.project-edit = {
            description = "Project editing with API access.";
            extends = ":workspace";
            filesystem = {
              ":minimal" = "read";
              ":workspace_roots" = {
                "**/*.env" = "deny";
                "." = "write";
              };
              glob_scan_max_depth = 8;
            };
            network = {
              domains = {
                "*.github.com" = "allow";
                "tracking.example.com" = "deny";
              };
              enabled = true;
              mode = "limited";
              unix_sockets."/var/run/docker.sock" = "allow";
            };
            workspace_roots."/home/test/project" = true;
          };
        };
      };
      hmSettings = hmCodexSettings (evalHm config);
      devenvSettings = (evalDevenv config).config.files.".codex/config.toml".source.value;
    in
      hmSettings
      == devenvSettings
      && hmSettings.default_permissions == "project-edit"
      && hmSettings.permissions.project-edit.filesystem.":minimal" == "read"
      && hmSettings.permissions.project-edit.filesystem.":workspace_roots"."**/*.env" == "deny"
      && hmSettings.permissions.project-edit.network.domains."*.github.com" == "allow"
  );

  module-codex-permission-profiles-toml-syntax = let
    evaluated = evalHm {
      ai.codex = {
        enable = true;
        settings = {
          default_permissions = "project-edit";
          permissions.project-edit = {
            extends = ":workspace";
            filesystem.":workspace_roots" = {
              "**/*.env" = "deny";
              "." = "write";
            };
            network = {
              domains."api.openai.com" = "allow";
              enabled = true;
            };
          };
        };
      };
    };
    source = tomlFormat.generate "codex-permission-profiles.toml" (hmCodexSettings evaluated);
  in
    pkgs.runCommand "module-test-codex-permission-profiles-toml-syntax" {} ''
      ${pkgs.gnugrep}/bin/grep -Fqx 'default_permissions = "project-edit"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '[permissions.project-edit.filesystem.":workspace_roots"]' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '"**/*.env" = "deny"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '[permissions.project-edit.network.domains]' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '"api.openai.com" = "allow"' ${source}
      touch "$out"
    '';

  module-codex-execpolicy-directory-source-is-rejected = mkTest "codex-execpolicy-directory-source-is-rejected" (
    let
      config.ai.codex = {
        enable = true;
        execpolicyRules.directory = ./fixtures;
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "path sources" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config)
      && rejects (evalDevenv config)
  );

  module-codex-execpolicy-missing-source-is-rejected = mkTest "codex-execpolicy-missing-source-is-rejected" (
    let
      config.ai.codex = {
        enable = true;
        execpolicyRules.missing = "/definitely/missing/codex.rules";
      };
      rejects = evaluated:
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "path sources" assertion.message)
        evaluated.config.assertions;
    in
      rejects (evalHm config)
      && rejects (evalDevenv config)
  );

  module-codex-execpolicy-parity = mkTest "codex-execpolicy-parity" (
    let
      config.ai.codex = {
        enable = true;
        execpolicyRules.git-read = ''
          prefix_rule(
              pattern = ["git", ["diff", "log", "show"]],
              decision = "allow",
          )
        '';
      };
      hmRule = (evalHm config).config.home.file.".codex/rules/git-read.rules".text;
      devenvRule = (evalDevenv config).config.files.".codex/rules/git-read.rules".text;
    in
      hmRule
      == devenvRule
      && lib.hasInfix ''decision = "allow"'' hmRule
  );

  module-codex-execpolicy-runs-native-checker = let
    evaluated = evalHm {
      ai.codex = {
        enable = true;
        execpolicyRules.git-read = ''
          prefix_rule(
              pattern = ["git", ["diff", "log", "show"]],
              decision = "allow",
              match = ["git show HEAD"],
              not_match = ["git status"],
          )
        '';
      };
    };
    rule = pkgs.writeText "git-read.rules" evaluated.config.home.file.".codex/rules/git-read.rules".text;
  in
    pkgs.runCommand "module-test-codex-execpolicy-runs-native-checker" {} ''
      ${pkgs.ai.chatgpt-codex}/bin/codex execpolicy check --pretty \
        --rules ${rule} \
        -- git show HEAD > result.json
      ${pkgs.gnugrep}/bin/grep -Fq '"decision": "allow"' result.json
      touch "$out"
    '';

  module-codex-execpolicy-separate-from-markdown-rules = mkTest "codex-execpolicy-separate-from-markdown-rules" (
    let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          execpolicyRules.command-policy = ''prefix_rule(pattern = ["git", "status"])'';
          rules.command-guidance.text = "Explain every command before running it.";
        };
      };
      agentsMd = evaluated.config.home.file.".codex/AGENTS.md".text;
      execpolicy = evaluated.config.home.file.".codex/rules/command-policy.rules".text;
    in
      lib.hasInfix "Explain every command" agentsMd
      && !lib.hasInfix "prefix_rule" agentsMd
      && lib.hasInfix "prefix_rule" execpolicy
  );

  module-codex-execpolicy-string-store-path-is-source = mkTest "codex-execpolicy-string-store-path-is-source" (
    let
      rule = pkgs.writeText "string-source.rules" ''prefix_rule(pattern = ["git", "status"])'';
      config.ai.codex = {
        enable = true;
        execpolicyRules.string-source = "${rule}";
      };
      hmSource = (evalHm config).config.home.file.".codex/rules/string-source.rules".source;
      devenvSource = (evalDevenv config).config.files.".codex/rules/string-source.rules".source;
    in
      hmSource
      == "${rule}"
      && devenvSource == "${rule}"
  );

  module-codex-execpolicy-symlinked-file-is-source = mkTest "codex-execpolicy-symlinked-file-is-source" (
    let
      rule = pkgs.writeText "symlink-target.rules" ''prefix_rule(pattern = ["git", "status"])'';
      symlink = pkgs.runCommand "symlink-source.rules" {} ''
        ln -s ${rule} "$out"
      '';
      config.ai.codex = {
        enable = true;
        execpolicyRules.symlink-source = "${symlink}";
      };
      hmSource = (evalHm config).config.home.file.".codex/rules/symlink-source.rules".source;
      devenvSource = (evalDevenv config).config.files.".codex/rules/symlink-source.rules".source;
    in
      hmSource
      == "${symlink}"
      && devenvSource == "${symlink}"
  );

  module-codex-execpolicy-user-default-is-reserved = mkTest "codex-execpolicy-user-default-is-reserved" (
    let
      config.ai.codex = {
        enable = true;
        execpolicyRules.default = ''prefix_rule(pattern = ["git", "status"])'';
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      hmFailure = lib.findFirst (assertion: !assertion.assertion) null hm.config.assertions;
    in
      hmFailure
      != null
      && lib.hasInfix "rules/default.rules" hmFailure.message
      && builtins.all (assertion: assertion.assertion) devenv.config.assertions
      && devenv.config.files.".codex/rules/default.rules".text != ""
  );

  module-codex-trust-is-user-global = mkTest "codex-trust-is-user-global" (
    let
      config.ai.codex = {
        enable = true;
        settings.projects."/home/test/project".trust_level = "trusted";
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      failed = lib.findFirst (assertion: !assertion.assertion) null devenv.config.assertions;
    in
      (hmCodexSettings hm).projects."/home/test/project".trust_level
      == "trusted"
      && failed != null
      && lib.hasInfix "projects" failed.message
  );

  module-codex-settings-toml-syntax = let
    evaluated = evalHm {
      ai.codex = {
        enable = true;
        settings = {
          features.memories = true;
          model = "custom-provider/model";
          model_reasoning_effort = "high";
        };
      };
    };
    source = tomlFormat.generate "codex-settings.toml" (hmCodexSettings evaluated);
  in
    pkgs.runCommand "module-test-codex-settings-toml-syntax" {} ''
      ${pkgs.gnugrep}/bin/grep -Fqx 'model = "custom-provider/model"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'model_reasoning_effort = "high"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx '[features]' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'memories = true' ${source}
      touch "$out"
    '';

  module-codex-settings-enums-reject-invalid = mkTest "codex-settings-enums-reject-invalid" (
    let
      accepts = name: value:
        (builtins.tryEval
          (hmCodexSettings (evalHm {
            ai.codex = {
              enable = true;
              settings.${name} = value;
            };
          })))
        .success;
      acceptsFeature = name: value:
        (builtins.tryEval
          (hmCodexSettings (evalHm {
            ai.codex = {
              enable = true;
              settings.features.${name} = value;
            };
          })))
        .success;
      acceptsPermission = path: value:
        (builtins.tryEval
          (hmCodexSettings (evalHm {
            ai.codex = {
              enable = true;
              settings.permissions.test = lib.setAttrByPath path value;
            };
          })))
        .success;
      # These two vocabularies come from recursive Clap help. Test the entire
      # extracted sets rather than one representative, so replacing the
      # factory's sidecar lookup with a stale handwritten subset goes red.
      extractedFlagValues = name: let
        matches = builtins.filter (flag: builtins.elem name flag.names) codexExtracted.cli.globalFlags;
        matchCount = builtins.length matches;
      in
        if matchCount == 1
        then (builtins.head matches).acceptedValues
        else throw "module-eval expected exactly one extracted Codex global flag record for ${name}, found ${toString matchCount}";
    in
      accepts "model_reasoning_effort" "max"
      && lib.all (accepts "approval_policy") (extractedFlagValues "--ask-for-approval")
      && accepts "approvals_reviewer" "auto_review"
      && accepts "personality" "friendly"
      && lib.all (accepts "sandbox_mode") (extractedFlagValues "--sandbox")
      && accepts "web_search" "live"
      && acceptsFeature "memories" true
      && acceptsFeature "speculative_future_flag" false
      && acceptsPermission ["filesystem" ":minimal"] "read"
      && acceptsPermission ["network" "domains" "api.openai.com"] "allow"
      && acceptsPermission ["network" "mode"] "limited"
      && !(accepts "model_reasoning_effort" "extreme")
      && !(accepts "approval_policy" "sometimes")
      && !(accepts "approvals_reviewer" "agent")
      && !(accepts "personality" "verbose")
      && !(accepts "sandbox_mode" "full")
      && !(accepts "web_search" "enabled")
      && !(acceptsFeature "memories" "yes")
      && !(acceptsFeature "speculative_future_flag" "no")
      && !(acceptsPermission ["filesystem" ":minimal"] "execute")
      && !(acceptsPermission ["filesystem" "glob_scan_max_depth"] 0)
      && !(acceptsPermission ["network" "domains" "api.openai.com"] "prompt")
      && !(acceptsPermission ["network" "mode"] "disabled")
  );

  module-codex-project-settings-reject-ignored-keys = mkTest "codex-project-settings-reject-ignored-keys" (
    let
      devenv = evalDevenv {
        ai.codex = {
          enable = true;
          settings = {
            model_provider = "custom";
            notify = ["notify-send"];
          };
        };
      };
      hm = evalHm {
        ai.codex = {
          enable = true;
          settings.model_provider = "custom";
        };
      };
      failed = lib.findFirst (assertion: !assertion.assertion) null devenv.config.assertions;
    in
      failed
      != null
      && lib.hasInfix "model_provider, notify" failed.message
      && (hmCodexSettings hm).model_provider == "custom"
  );

  module-codex-semantic-agents-fanout = mkTest "codex-semantic-agents-fanout" (
    let
      config.ai = {
        agents = {
          emptyTools = {
            description = "Review with an explicitly empty tool restriction.";
            instructions = "Report concrete findings.";
            tools = [];
          };
          reviewer = {
            codex = {
              model = "review-model";
              sandbox_mode = "read-only";
            };
            description = "Review changes for correctness.";
            instructions = "Read first, then report concrete findings.";
            tools = ["Bash" "Read"];
          };
          unrestricted = {
            description = "Review without a portable tool restriction.";
            instructions = "Report concrete findings.";
          };
        };
        claude.enable = true;
        codex.enable = true;
        copilot.enable = true;
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      expected = {
        description = "Review changes for correctness.";
        developer_instructions = "Read first, then report concrete findings.";
        model = "review-model";
        name = "reviewer";
        sandbox_mode = "read-only";
      };
      hmAgent = hm.config.home.file.".codex/agents/reviewer.toml".source.value;
      devenvAgent = devenv.config.files.".codex/agents/reviewer.toml".source.value;
      claudeAgent = hm.config.programs.claude-code.agents.reviewer;
      emptyClaudeAgent = hm.config.programs.claude-code.agents.emptyTools;
      emptyCopilotAgent = devenv.config.files.".github/agents/emptyTools.agent.md".text;
      unrestrictedClaudeAgent = hm.config.programs.claude-code.agents.unrestricted;
      copilotAgent = devenv.config.files.".github/agents/reviewer.agent.md".text;
    in
      hmAgent
      == expected
      && devenvAgent == expected
      && lib.hasPrefix "---\n" claudeAgent
      && lib.hasInfix ''name: "reviewer"'' claudeAgent
      && lib.hasInfix ''description: "Review changes for correctness."'' claudeAgent
      && lib.hasInfix "tools: Bash, Read" claudeAgent
      && !(lib.hasInfix "tools:" emptyClaudeAgent)
      && !(lib.hasInfix "tools:" emptyCopilotAgent)
      && lib.hasPrefix "---\n" unrestrictedClaudeAgent
      && lib.hasInfix ''description: "Review without a portable tool restriction."'' unrestrictedClaudeAgent
      && !(lib.hasInfix "tools:" unrestrictedClaudeAgent)
      && lib.hasInfix "Read first, then report concrete findings." copilotAgent
      && lib.hasInfix "tools: Bash, Read" copilotAgent
      && !(lib.hasInfix "name:" copilotAgent)
  );

  module-codex-agent-toml-syntax = let
    evaluated = evalHm {
      ai.codex = {
        enable = true;
        agents.reviewer = {
          codex = {
            model = "review-model";
            sandbox_mode = "read-only";
          };
          description = "Review changes.";
          instructions = "Report concrete findings.";
        };
      };
    };
    source = evaluated.config.home.file.".codex/agents/reviewer.toml".source;
  in
    pkgs.runCommand "module-test-codex-agent-toml-syntax" {} ''
      ${pkgs.gnugrep}/bin/grep -Fqx 'name = "reviewer"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'model = "review-model"' ${source}
      ${pkgs.gnugrep}/bin/grep -Fqx 'sandbox_mode = "read-only"' ${source}
      touch "$out"
    '';

  module-codex-agent-collision-fails = mkTest "codex-agent-collision-fails" (
    let
      semantic = {
        description = "Review.";
        instructions = "Review carefully.";
      };
      result = evalHm {
        ai = {
          agents.reviewer = semantic;
          codex = {
            enable = true;
            agents.reviewer = semantic;
          };
        };
      };
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "agents 'reviewer' declared in both" assertion.message)
      result.config.assertions
  );

  module-codex-legacy-markdown-agent-fails-loudly = mkTest "codex-legacy-markdown-agent-fails-loudly" (
    let
      result = evalHm {
        ai.codex.enable = true;
        ai.agents.legacy = "# Legacy Markdown agent";
      };
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "must use the portable" assertion.message)
      result.config.assertions
  );

  module-codex-agent-native-reserved-keys-fail = mkTest "codex-agent-native-reserved-keys-fail" (
    let
      result = evalDevenv {
        ai.codex = {
          enable = true;
          agents.reviewer = {
            description = "Review.";
            instructions = "Review carefully.";
            codex.name = "different-name";
          };
        };
      };
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "keep name/description/developer_instructions out" assertion.message)
      result.config.assertions
  );

  module-codex-agent-defaults-parity = mkTest "codex-agent-defaults-parity" (
    let
      config.ai.codex = {
        enable = true;
        settings.agents = {
          default_subagent_model = "worker-model";
          default_subagent_reasoning_effort = "high";
          enabled = true;
          interrupt_message = false;
          max_concurrent_threads_per_session = 7;
        };
      };
      hmAgents = (hmCodexSettings (evalHm config)).agents;
      devenvAgents = (evalDevenv config).config.files.".codex/config.toml".source.value.agents;
    in
      hmAgents
      == devenvAgents
      && hmAgents.default_subagent_model == "worker-model"
      && hmAgents.default_subagent_reasoning_effort == "high"
      && hmAgents.max_concurrent_threads_per_session == 7
      && !hmAgents.interrupt_message
  );

  module-codex-hooks-fanout-parity = mkTest "codex-hooks-fanout-parity" (
    let
      config.ai = {
        claude.enable = true;
        codex = {
          enable = true;
          hooks.PreToolUse = [
            {
              matcher = "apply_patch";
              hooks = [
                {
                  additionalContextLimit = 0;
                  command = "review-patch";
                  commandWindows = "review-patch.exe";
                  statusMessage = "Reviewing patch";
                  timeout = 30;
                }
              ];
            }
          ];
        };
        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [{command = pkgs.hello;}];
          }
        ];
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      hmHooks = hm.config.home.file.".codex/hooks.json".source.value;
      devenvHooks = devenv.config.files.".codex/hooks.json".source.value;
      blocks = hmHooks.hooks.PreToolUse;
      sharedHandler = builtins.head (builtins.head blocks).hooks;
      nativeHandler = builtins.head (builtins.elemAt blocks 1).hooks;
      claudeBlocks = hm.config.programs.claude-code.settings.hooks.PreToolUse;
    in
      hmHooks
      == devenvHooks
      && builtins.length blocks == 2
      && lib.hasSuffix "/bin/hello" sharedHandler.command
      && nativeHandler.additionalContextLimit == 0
      && nativeHandler.commandWindows == "review-patch.exe"
      && nativeHandler.statusMessage == "Reviewing patch"
      && builtins.length claudeBlocks == 1
      && (builtins.head claudeBlocks).matcher == "Bash"
  );

  module-codex-hooks-inline-source-collision-fails = mkTest "codex-hooks-inline-source-collision-fails" (
    let
      result = evalHm {
        ai.codex = {
          enable = true;
          hooks.Stop = [{hooks = [{command = "validate";}];}];
          settings.hooks.Stop = [{hooks = [{command = "legacy";}];}];
        };
      };
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "cannot be combined with ai.codex.settings.hooks" assertion.message)
      result.config.assertions
  );

  module-codex-hooks-json-syntax = let
    evaluated = evalDevenv {
      ai.codex = {
        enable = true;
        hooks.Stop = [{hooks = [{command = "validate";}];}];
      };
    };
    source = evaluated.config.files.".codex/hooks.json".source;
  in
    pkgs.runCommand "module-test-codex-hooks-json-syntax" {} ''
      ${pkgs.jq}/bin/jq -e '.hooks.Stop[0].hooks[0]
        | .type == "command" and .command == "validate"' ${source} >/dev/null
      touch "$out"
    '';

  module-shared-hooks-reject-non-portable-event = mkTest "shared-hooks-reject-non-portable-event" (!(builtins.tryEval (
    builtins.deepSeq
    (evalHm {
      ai.hooks.ConfigChange = [{hooks = [{command = "true";}];}];
    }).config.ai.hooks
    true
  )).success);

  module-codex-agentsmd-fanout = mkTest "codex-agentsmd-fanout" (
    let
      config = {
        ai = {
          codex = {
            context = "Codex context";
            enable = true;
            instructions = [
              {
                name = "local";
                text = "Local instruction";
              }
            ];
            rules.zeta.text = "Zeta rule";
          };
          context = "Shared context";
          instructions = [{text = "Shared instruction";}];
          rules.alpha.text = "Alpha rule";
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      expected = builtins.concatStringsSep "\n\n" [
        "Codex context"
        "Shared instruction"
        "<!-- instruction: local -->\nLocal instruction"
        "<!-- rule: alpha -->\nAlpha rule"
        "<!-- rule: zeta -->\nZeta rule"
      ];
    in
      hm.config.home.file.".codex/AGENTS.md".text
      == expected
      && devenv.config.files."AGENTS.md".text == expected
      && !(lib.hasInfix "---" expected)
  );

  module-codex-context-fallback-and-empty-gate = mkTest "codex-context-fallback-and-empty-gate" (
    let
      hm = evalHm {
        ai = {
          codex.enable = true;
          context = "Shared context";
        };
      };
      empty = evalHm {ai.codex.enable = true;};
    in
      hm.config.home.file.".codex/AGENTS.md".text
      == "Shared context"
      && !(empty.config.home.file ? ".codex/AGENTS.md")
  );

  module-codex-empty-path-context-does-not-prefix-separator = mkTest "codex-empty-path-context-does-not-prefix-separator" (
    let
      evaluated = evalHm {
        ai = {
          codex.enable = true;
          context = ./fixtures/empty;
          instructions = [{text = "Instruction";}];
        };
      };
    in
      evaluated.config.home.file.".codex/AGENTS.md".text == "Instruction"
  );

  module-codex-configdir-rejects-unsafe-paths = mkTest "codex-configdir-rejects-unsafe-paths" (
    let
      accepts = configDir:
        (builtins.tryEval
          (evalHm {
            ai.codex = {
              inherit configDir;
              enable = true;
            };
          }).config.ai.codex.configDir)
        .success;
    in
      accepts ".codex"
      && !(accepts "")
      && !(accepts "/tmp/codex")
      && !(accepts "../codex")
      && !(accepts "config/../codex")
  );

  module-codex-path-instruction-resolves = mkTest "codex-path-instruction-resolves" (
    let
      evaluated = evalHm {
        ai = {
          codex.enable = true;
          instructions = [{text = ./fixtures/kiro-steering/alpha.md;}];
        };
      };
    in
      evaluated.config.home.file.".codex/AGENTS.md".text == "Alpha steering body.\n"
  );

  module-codex-scoped-content-degrades-to-prose = mkTest "codex-scoped-content-degrades-to-prose" (
    let
      config = {
        ai = {
          codex = {
            enable = true;
            instructions = [
              {
                name = "nix";
                paths = ["**/*.nix" "flake.lock"];
                text = "Scoped instruction";
              }
            ];
          };
          rules.scoped = {
            paths = ["src/**"];
            text = "Scoped rule";
          };
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
      expected = builtins.concatStringsSep "\n\n" [
        "<!-- instruction: nix -->\n_Apply this guidance only when working with files matching: `**/*.nix`, `flake.lock`_\n\nScoped instruction"
        "<!-- rule: scoped -->\n_Apply this guidance only when working with files matching: `src/**`_\n\nScoped rule"
      ];
    in
      hm.config.home.file.".codex/AGENTS.md".text
      == expected
      && devenv.config.files."AGENTS.md".text == expected
  );

  module-codex-scoped-content-can-skip = mkTest "codex-scoped-content-can-skip" (
    let
      evaluated = evalHm {
        ai = {
          codex = {
            enable = true;
            instructions = [
              {
                paths = ["**/*.nix"];
                skipIfUnsupported = true;
                text = "Skipped instruction";
              }
            ];
          };
          context = "Kept context";
          rules.skipped = {
            paths = ["src/**"];
            skipIfUnsupported = true;
            text = "Skipped rule";
          };
        };
      };
    in
      evaluated.config.home.file.".codex/AGENTS.md".text == "Kept context"
  );

  module-codex-empty-scope-fails-loudly = mkTest "codex-empty-scope-fails-loudly" (
    let
      evaluated = evalHm {
        ai = {
          codex = {
            enable = true;
            instructions = [
              {
                paths = [];
                text = "Ambiguous";
              }
            ];
          };
          rules.empty = {
            paths = [];
            text = "Ambiguous";
          };
        };
      };
      failedMessages = map (assertion: assertion.message) (
        builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions
      );
    in
      builtins.any (lib.hasInfix "ai.codex.instructions[0].paths") failedMessages
      && builtins.any (lib.hasInfix "ai.codex.rules.empty.paths") failedMessages
      && builtins.all (lib.hasInfix "must be null or a non-empty list") failedMessages
  );

  module-codex-size-guard-byte-boundaries = mkTest "codex-size-guard-byte-boundaries" (
    let
      evaluate = context: projectDocMaxBytes:
        evalHm {
          ai.codex = {
            inherit context;
            enable = true;
            inherit projectDocMaxBytes;
          };
        };
      sized = size: lib.concatStrings (lib.replicate size "x");
      below = evaluate (sized 32767) 32768;
      exact = evaluate (sized 32768) 32768;
      above = evaluate (sized 32769) 32768;
      diagnostic = evalHm {
        ai = {
          codex = {
            enable = true;
            instructions = [
              {
                name = "named";
                text = "i";
              }
            ];
            projectDocMaxBytes = 1;
          };
          rules.oversize.text = "r";
        };
      };
      unicodeOver = evaluate "é" 1;
      aboveAssertion = lib.findFirst (assertion: !assertion.assertion) null above.config.assertions;
      diagnosticAssertion = lib.findFirst (assertion: !assertion.assertion) null diagnostic.config.assertions;
      unicodeAssertion = lib.findFirst (assertion: !assertion.assertion) null unicodeOver.config.assertions;
    in
      builtins.all (assertion: assertion.assertion) below.config.assertions
      && builtins.all (assertion: assertion.assertion) exact.config.assertions
      && aboveAssertion != null
      && lib.hasInfix "renders to 32769 bytes" aboveAssertion.message
      && lib.hasInfix "projectDocMaxBytes (32768 bytes)" aboveAssertion.message
      && diagnosticAssertion != null
      && lib.hasInfix "instruction:named=" diagnosticAssertion.message
      && lib.hasInfix "rule:oversize=" diagnosticAssertion.message
      && unicodeAssertion != null
      && lib.hasInfix "renders to 2 bytes" unicodeAssertion.message
      && lib.hasInfix "projectDocMaxBytes (1 bytes)" unicodeAssertion.message
      && lib.hasInfix "context=2 bytes" unicodeAssertion.message
      && lib.hasInfix "Trim the contributing content or raise" unicodeAssertion.message
  );

  module-codex-rule-collision-fails = mkTest "codex-rule-collision-fails" (
    let
      evaluated = evalHm {
        ai = {
          codex = {
            enable = true;
            rules.duplicate.text = "Codex";
          };
          rules.duplicate.text = "Shared";
        };
      };
    in
      builtins.any (assertion: !assertion.assertion && lib.hasInfix "rules 'duplicate'" assertion.message) evaluated.config.assertions
  );

  # ── Semble convenience integration ───────────────────────────────
  module-semble-default-disabled = mkTest "semble-default-disabled" (
    let
      hm = evalHm {};
      devenv = evalDevenv {};
      clean = evaluated:
        !evaluated.config.semble.enable
        && evaluated.config.semble.mcp.enable == null
        && !(evaluated.config.ai.claude.mcpServers ? semble)
        && !(evaluated.config.ai.codex.agents ? semble-search)
        && !(evaluated.config.ai.kiro.agents ? semble-search);
    in
      clean hm
      && clean devenv
      && hm.config.home.packages == []
      && devenv.config.packages == []
  );

  module-semble-codex-sandbox-cache-parity = mkTest "semble-codex-sandbox-cache-parity" (
    let
      config = {
        ai.codex = {
          enable = true;
          settings = {
            sandbox_mode = "workspace-write";
            sandbox_workspace_write.writable_roots = ["/consumer-cache"];
          };
        };
        semble = {
          enable = true;
          runtimes = ["codex"];
        };
      };
      hm = (evalHm config).config;
      devenv = (evalDevenv config).config;
      readOnly =
        (evalDevenv {
          ai.codex.settings.sandbox_mode = "read-only";
          semble = {
            enable = true;
            runtimes = ["codex"];
          };
        }).config;
      noCodex =
        (evalDevenv {
          ai.codex.settings.sandbox_mode = "workspace-write";
          semble = {
            enable = true;
            runtimes = ["claude"];
          };
        }).config;
      profileOnly =
        (evalDevenv {
          ai.codex.settings = {
            default_permissions = "project-edit";
            permissions.project-edit.description = "Project edit profile.";
          };
          semble = {
            enable = true;
            runtimes = ["codex"];
          };
        }).config;
    in
      builtins.all
      (root: builtins.elem root hm.ai.codex.settings.sandbox_workspace_write.writable_roots)
      ["/consumer-cache" "/home/test/.cache/nix" "/home/test/.cache/semble"]
      && builtins.length hm.ai.codex.settings.sandbox_workspace_write.writable_roots == 3
      && builtins.all
      (root: builtins.elem root devenv.ai.codex.settings.sandbox_workspace_write.writable_roots)
      ["/consumer-cache" "/tmp/devenv-root/.git" "/tmp/devenv-state/semble-cache"]
      # HM leaves the cache at semble's own default, so semble needs telling
      # nothing and the package ships unwrapped.
      && builtins.elem aiStubs.semble hm.home.packages
      # devenv RELOCATES it project-local, so semble is told through its
      # launcher wrapper. Never through the project shell: that would export
      # the value to the developer's session and everything else in it. The
      # `env.SEMBLE_CACHE_LOCATION` override this test used to exercise is
      # deliberately gone — devenv/Nix is the only config path.
      && builtins.any
      (drv:
        lib.hasSuffix "${lib.getName aiStubs.semble}-wrapped" (
          builtins.baseNameOf drv
        ))
      devenv.packages
      && readOnly.ai.codex.settings.sandbox_workspace_write == null
      && noCodex.ai.codex.settings.sandbox_workspace_write == null
      && profileOnly.ai.codex.settings.sandbox_workspace_write == null
      && builtins.all (assertion: assertion.assertion) profileOnly.assertions
  );

  # CONTENT coverage for semble's relocated cache. The parity test above can
  # only assert the derivation NAME, which symlinkJoin emits whether or not
  # the wrapper actually carries anything — so on its own it would pass a
  # wrapper that sets nothing at all. This greps every entry point, because
  # `semble` and `semble-mcp` disagreeing about the cache location is the
  # specific failure the single-wrapper design exists to prevent.
  module-semble-devenv-cache-in-every-entry-point = let
    semblePackage =
      builtins.head
      (evalDevenv {
        semble = {
          enable = true;
          runtimes = ["codex"];
        };
      })
      .config
      .packages;
  in
    pkgs.runCommand "module-test-semble-devenv-cache-in-every-entry-point" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      pkg=${semblePackage}
      found=0
      for bin in "$pkg"/bin/*; do
        found=$((found + 1))
        grep -qF -- 'SEMBLE_CACHE_LOCATION' "$bin" \
          || { echo "FAIL: $bin does not carry SEMBLE_CACHE_LOCATION" >&2; exit 1; }
        grep -qF -- '/semble-cache' "$bin" \
          || { echo "FAIL: $bin does not carry the relocated cache path" >&2; exit 1; }
      done
      # An empty bin/ would pass the loop vacuously.
      [ "$found" -gt 0 ] || { echo "FAIL: wrapper exposes no entry points" >&2; exit 1; }
      echo PASS > "$out"
    '';

  module-semble-umbrella-fanout = mkTest "semble-umbrella-fanout" (
    let
      evaluated = evalHm {semble.enable = true;};
      cfg = evaluated.config;
      claudeInstruction = builtins.head cfg.ai.claude.instructions;
      codexInstruction = builtins.head cfg.ai.codex.instructions;
      # Semble's Kiro agent is a TYPED record now. Semble deliberately does not
      # set `ai.kiro.enable` (selecting a runtime configures it; activating it
      # stays the consumer's call), so nothing is EMITTED here — this test
      # covers the fanout of option VALUES. `name` staying null in the record
      # is the contract: the emitter defaults it from the attr key, which is
      # asserted end-to-end in `semble-kiro-agent-emits-name` below.
      kiroAgentName = "semble-search";
      kiroAgentRecord = cfg.ai.kiro.agents.${kiroAgentName};
      kiroInstruction = builtins.head cfg.ai.kiro.instructions;
    in
      builtins.length cfg.home.packages
      == 1
      && lib.all (runtime: cfg.ai.${runtime}.mcpServers ? semble) ["claude" "codex" "kiro"]
      && lib.all (runtime: builtins.length cfg.ai.${runtime}.instructions == 1) ["claude" "codex" "kiro"]
      && cfg.ai.claude.agents ? semble-search
      && cfg.ai.codex.agents ? semble-search
      && cfg.ai.kiro.agents ? ${kiroAgentName}
      && cfg.ai.claude.agents.semble-search.tools == ["Bash" "Read"]
      && !(claudeInstruction ? name)
      && !(codexInstruction ? name)
      && kiroAgentRecord.name == null
      && kiroAgentRecord.description != null
      && kiroAgentRecord.tools == ["shell" "read"]
      # `prompt` is a Nix path in the record; the option's readFile coercion
      # inlines it. A store path here would mean the path was stringified
      # instead of read.
      && !(lib.hasPrefix builtins.storeDir kiroAgentRecord.prompt)
      && lib.hasInfix "semble" kiroAgentRecord.prompt
      && kiroInstruction.name == "semble"
      && !(cfg.ai.copilot.mcpServers ? semble)
      && !(cfg.ai.copilot.agents ? semble-search)
      && cfg.ai.copilot.instructions == []
  );

  # End-to-end regression guard for the defect that motivated typing this
  # surface: Semble's agent file shipped WITHOUT `name`, so Kiro's Rust CLI
  # rejected it with "missing field name" on every invocation and the agent
  # never loaded, while the Node/ACP parser (which treats `name` as optional)
  # kept working and hid it. With Kiro actually enabled the file must carry
  # `name` equal to its attr key — which is also its filename stem.
  module-semble-kiro-agent-emits-name = mkTest "semble-kiro-agent-emits-name" (
    let
      cfg =
        (evalHm {
          semble.enable = true;
          ai.kiro.enable = true;
        }).config;
      emitted =
        builtins.fromJSON
        cfg.home.file.".kiro/agents/semble-search.json".text;
    in
      emitted.name
      == "semble-search"
      && emitted.tools == ["shell" "read"]
      && emitted ? description
      && !(lib.hasPrefix builtins.storeDir emitted.prompt)
  );

  module-semble-feature-enable-overrides = mkTest "semble-feature-enable-overrides" (
    let
      onlyMcp = (evalDevenv {semble.mcp.enable = true;}).config;
      noMcp =
        (evalDevenv {
          semble = {
            enable = true;
            mcp.enable = false;
          };
        }).config;
    in
      builtins.length onlyMcp.packages
      == 1
      && onlyMcp.ai.claude.mcpServers ? semble
      && onlyMcp.ai.claude.instructions == []
      && !(onlyMcp.ai.claude.agents ? semble-search)
      && !(noMcp.ai.claude.mcpServers ? semble)
      && builtins.length noMcp.ai.claude.instructions == 1
      && noMcp.ai.claude.agents ? semble-search
  );

  module-semble-runtime-selection = mkTest "semble-runtime-selection" (
    let
      top =
        (evalHm {
          semble = {
            enable = true;
            runtimes = ["codex"];
          };
        }).config;
      perFeature =
        (evalDevenv {
          semble = {
            enable = true;
            instructions.runtimes = ["claude"];
            mcp.runtimes = ["kiro"];
            subagent.runtimes = ["codex"];
          };
        }).config;
    in
      top.ai.codex.mcpServers ? semble
      && top.ai.codex.agents ? semble-search
      && builtins.length top.ai.codex.instructions == 1
      && !(top.ai.claude.mcpServers ? semble)
      && !(top.ai.kiro.agents ? semble-search)
      && perFeature.ai.kiro.mcpServers ? semble
      && !(perFeature.ai.claude.mcpServers ? semble)
      && builtins.length perFeature.ai.claude.instructions == 1
      && perFeature.ai.codex.instructions == []
      && perFeature.ai.codex.agents ? semble-search
      && !(perFeature.ai.kiro.agents ? semble-search)
  );

  module-semble-mcp-content-and-default-refinement = mkTest "semble-mcp-content-and-default-refinement" (
    let
      code = (evalHm {semble.mcp.enable = true;}).config.ai.claude.mcpServers.semble;
      docs =
        (evalHm {
          semble = {
            mcp = {
              content = "docs";
              enable = true;
            };
          };
        }).config.ai.claude.mcpServers.semble;
      refined =
        (evalHm {
          ai.codex.mcpServers.semble.args = ["--log-level" "debug"];
          semble = {
            enable = true;
            runtimes = ["codex"];
          };
        }).config.ai.codex.mcpServers.semble;
    in
      code.args
      == []
      && lib.hasSuffix "/bin/semble-mcp" code.command
      && docs.args == ["--content" "docs"]
      && refined.args == ["--log-level" "debug"]
      && lib.hasSuffix "/bin/semble-mcp" refined.command
  );

  module-semble-package-override-and-named-kiro-instruction = mkTest "semble-package-override-and-named-kiro-instruction" (
    let
      evaluated = evalDevenv {
        semble = {
          instructions.enable = true;
          package = pkgs.hello;
          runtimes = ["kiro"];
        };
      };
      instruction = builtins.head evaluated.config.ai.kiro.instructions;
    in
      # devenv relocates the cache, so semble is installed WRAPPED. The
      # wrapper is named after what it wraps, which is what keeps the
      # `package` override observable here rather than hidden behind a
      # fixed derivation name.
      builtins.length evaluated.config.packages
      == 1
      && lib.hasSuffix "hello-wrapped" (
        builtins.baseNameOf (builtins.head evaluated.config.packages)
      )
      && evaluated.config.ai.kiro.mcpServers == {}
      && instruction.name == "semble"
      && instruction.text == ../packages/semble/agent-instructions.md
  );

  module-semble-instructions-use-native-files = mkTest "semble-instructions-use-native-files" (
    let
      nativeConfig = {
        ai = {
          claude.enable = true;
          codex.enable = true;
          kiro.enable = true;
        };
        semble.instructions.enable = true;
      };
      hm = (evalHm nativeConfig).config;
      devenv = (evalDevenv nativeConfig).config;
      hmKiroSteering = hm.ai.kiro.steeringFiles;
      devenvKiroSteering = devenv.ai.kiro.steeringFiles;
      hmKiroInstruction = (hmKiroSteering."semble.md" or {}).text or "";
      devenvKiroInstruction = (devenvKiroSteering."semble.md" or {}).text or "";
    in
      lib.hasInfix "Use `semble search`" (hm.programs.claude-code.context or "")
      && lib.hasInfix "Use `semble search`" (hm.home.file.".codex/AGENTS.md".text or "")
      && hmKiroSteering ? "semble.md"
      && !(hmKiroSteering ? "instructions.md")
      && lib.hasInfix "name: semble" hmKiroInstruction
      && lib.hasInfix "inclusion: always" hmKiroInstruction
      && devenvKiroSteering ? "semble.md"
      && !(devenvKiroSteering ? "instructions.md")
      && hmKiroInstruction == devenvKiroInstruction
  );

  module-semble-hm-devenv-option-parity = mkTest "semble-hm-devenv-option-parity" (
    let
      optionType = option: option.type.description;
      optionShape = evaluated: {
        enable = optionType evaluated.options.semble.enable;
        package = optionType evaluated.options.semble.package;
        runtimes = optionType evaluated.options.semble.runtimes;
        instructions = lib.mapAttrs (_: optionType) evaluated.options.semble.instructions;
        mcp = lib.mapAttrs (_: optionType) evaluated.options.semble.mcp;
        subagent = lib.mapAttrs (_: optionType) evaluated.options.semble.subagent;
      };
    in
      optionShape (evalHm {}) == optionShape (evalDevenv {})
  );

  module-semble-direct-helpers = mkTest "semble-direct-helpers" (
    let
      mkSemble = import ../packages/semble/lib/mkSemble.nix;
      helperPkgs = pkgs // {ai = aiStubs;};
      code = mkSemble {
        lib = hmLib;
        pkgs = helperPkgs;
      } {};
      all = mkSemble {
        lib = hmLib;
        pkgs = helperPkgs;
      } {content = "all";};
      records = import ../packages/semble/lib/integrations.nix;
    in
      code.type
      == "stdio"
      && code.args == []
      && lib.hasSuffix "/bin/semble-mcp" code.command
      && all.args == ["--content" "all"]
      && records.instruction.text == ../packages/semble/agent-instructions.md
      && records.kiroInstruction.name == "semble"
      && records.kiroInstruction.text == records.instruction.text
      && records.semanticAgent.instructions == ../packages/semble/agent-instructions.md
      && records.semanticAgent.tools == ["Bash" "Read"]
      # `kiroAgent` is a typed record, not pre-rendered JSON. It deliberately
      # carries NO `name`: the typed `ai.kiro.agents` option defaults that from
      # the attr key, which keeps the id and the filename a single source of
      # truth. `prompt` stays a path here and is readFile-coerced at emission.
      && records.kiroAgent.tools == ["shell" "read"]
      && !(records.kiroAgent ? name)
      && records.kiroAgent.prompt == ../packages/semble/agent-instructions.md
  );

  # ── glab ───────────────────────────────────────────────────────────
  module-glab-default-disabled = mkTest "glab-default-disabled" (
    !(evalHm {}).config.glab.enable && (evalHm {}).config.home.packages == []
  );

  # The settings surface is GENERATED from overlays/dev-tools/glab-extracted.json.
  # Assert the shape of what was generated rather than a count: a key that
  # upstream renames must show up as a failure here, and an option tree that
  # collapsed to nothing must not read as "fine".
  module-glab-settings-generated-from-schema = mkTest "glab-settings-generated-from-schema" (
    let
      opts = (evalHm {}).options.glab;
      settingNames =
        builtins.attrNames
        (lib.filterAttrs (n: _: n != "_module") (opts.settings.type.getSubOptions []));
    in
      builtins.elem "git_protocol" settingNames
      && builtins.elem "check_update" settingNames
      && builtins.elem "glamour_style" settingNames
      # host/token/job_token are secret-capable and live at the top level,
      # so they must NOT also appear as plain settings.
      && !(builtins.elem "host" settingNames)
      && !(builtins.elem "token" settingNames)
      && !(builtins.elem "job_token" settingNames)
      # custom_headers is list-typed and has no single-env-var spelling.
      && !(builtins.elem "custom_headers" settingNames)
      && builtins.length settingNames > 20
  );

  # The three-branch union must accept each branch, and the type system
  # (not a runtime throw) is what forbids setting two at once.
  module-glab-secret-branches-accepted = mkTest "glab-secret-branches-accepted" (
    let
      ev = evalHm {
        glab = {
          enable = true;
          host.plain = "gitlab.example.com";
          token.file = "/run/secrets/gitlab-token";
          job_token.helper = "/run/wrappers/bin/job-token";
        };
      };
    in
      ev.config.glab.host
      == {plain = "gitlab.example.com";}
      && ev.config.glab.token == {file = "/run/secrets/gitlab-token";}
      && ev.config.glab.job_token == {helper = "/run/wrappers/bin/job-token";}
      && builtins.length ev.config.home.packages == 1
  );

  # The whole point of the wrapper: a `file` secret must appear as a
  # RUNTIME read, and its contents must never be interpolated. A `plain`
  # value is allowed in the script; a file path is only ever `cat`ed.
  module-glab-wrapper-reads-secrets-at-runtime = mkTest "glab-wrapper-reads-secrets-at-runtime" (
    let
      ev = evalHm {
        glab = {
          enable = true;
          host.file = "/run/secrets/gitlab-url";
          token.file = "/run/secrets/gitlab-token";
          settings.git_protocol = "ssh";
          extraSettings.brand_new_key = "value";
        };
      };
      wrapped = builtins.head ev.config.home.packages;
      # The script SOURCE — reading its store path back would be IFD
      # inside `nix flake check`.
      script = wrapped.passthru.wrapperText;
    in
      # Secrets: read at invocation, never baked.
      lib.hasInfix ''GITLAB_HOST="$('' script
      && lib.hasInfix "/run/secrets/gitlab-url" script
      && lib.hasInfix ''GITLAB_TOKEN="$('' script
      # Non-secret setting exports under its real env var. Asserting the
      # assignment and the export, NOT the quoting: nixpkgs'
      # `escapeShellArg` elides quotes for shell-safe values, so
      # "GIT_PROTOCOL='ssh'" would be an assertion about lib internals.
      && lib.hasInfix "GIT_PROTOCOL=" script
      && lib.hasInfix "export GIT_PROTOCOL" script
      # extraSettings uses glab's uppercase fallback.
      && lib.hasInfix "BRAND_NEW_KEY=" script
      # Absolute store path for cat — the wrapper may run without PATH.
      && !(lib.hasInfix "$(cat " script)
      # Each env var is exported exactly once. A duplicated export is
      # harmless at runtime but means the key partitioning has drifted
      # between the options and the wrapper — which it once had.
      && builtins.length
      (builtins.filter (l: l == "export GITLAB_HOST")
        (lib.splitString "\n" script))
      == 1
  );

  module-glab-keyring-sync-hm-wiring = mkTest "glab-keyring-sync-hm-wiring" (
    let
      ev = evalHm {
        glab = {
          enable = true;
          host.file = "/run/secrets/gitlab-url";
          keyringSync.enable = true;
          settings.git_protocol = "ssh";
          token.file = "/run/secrets/gitlab-token";
        };
      };
      pendingFile = "/home/test/.local/state/glab/keyring-sync-pending";
      sync = import ../packages/glab/lib/mkKeyringSync.nix {
        cfg = ev.config.glab;
        configDir = "/home/test/.config/glab-cli";
        inherit lib pkgs;
        inherit pendingFile;
      };
      activation = ev.config.home.activation.glabKeyringSync.text;
      pathUnit = ev.config.systemd.user.paths.glab-keyring-sync;
      service = ev.config.systemd.user.services.glab-keyring-sync;
      wrapper = (builtins.head ev.config.home.packages).passthru.wrapperText;
      scriptAfterProbe = builtins.elemAt (lib.splitString "secret-tool store" sync.scriptText) 1;
    in
      service.Service.Type
      == "oneshot"
      && service.Service.Restart == "no"
      && service.Service.TimeoutStartSec == "5min"
      && pathUnit.Path.PathExists == pendingFile
      && pathUnit.Install.WantedBy == ["graphical-session.target"]
      && lib.hasInfix pendingFile activation
      # Splitting after the only probe invocation proves both runtime secret
      # paths occur later in the generated script, not merely somewhere in it.
      && lib.hasInfix "secret-tool store" sync.scriptText
      && lib.hasInfix "/run/secrets/gitlab-url" scriptAfterProbe
      && lib.hasInfix "/run/secrets/gitlab-token" scriptAfterProbe
      && lib.hasInfix "--stdin" sync.scriptText
      && lib.hasInfix "--use-keyring" sync.scriptText
      && !(lib.hasInfix "--insecure-storage" sync.scriptText)
      # The synchronized token flows over stdin and is no longer exported by
      # the ordinary wrapper, where it would override keyring storage.
      && !(lib.hasInfix "export glab_sync_token" sync.scriptText)
      && !(lib.hasInfix "export GITLAB_TOKEN" wrapper)
      && lib.hasInfix "export GITLAB_HOST" wrapper
  );

  module-glab-keyring-sync-boundaries = mkTest "glab-keyring-sync-boundaries" (
    let
      failedMessages = ev:
        map (entry: entry.message)
        (builtins.filter (entry: !entry.assertion) ev.config.assertions);
      devenv = evalDevenv {
        glab = {
          enable = true;
          host.plain = "gitlab.example.com";
          keyringSync.enable = true;
          token.file = "/run/secrets/gitlab-token";
        };
      };
      plainToken = evalHm {
        glab = {
          enable = true;
          host.plain = "gitlab.example.com";
          keyringSync.enable = true;
          token.plain = "store-visible-token";
        };
      };
      disabled = evalHm {glab.keyringSync.enable = true;};
    in
      builtins.elem
      "glab.keyringSync.enable is Home Manager-only: devenv may consume a user's existing keyring, but a repository shell must not own login or graphical-session services."
      (failedMessages devenv)
      && builtins.elem
      "glab.keyringSync.enable requires glab.token.file or glab.token.helper; token.plain would already expose the token through the Nix store."
      (failedMessages plainToken)
      && builtins.elem
      "glab.keyringSync.enable requires glab.enable."
      (failedMessages disabled)
  );

  # HM and devenv must expose the SAME option tree — that is the whole
  # reason the declarations are one shared file.
  module-glab-hm-devenv-option-parity = mkTest "glab-hm-devenv-option-parity" (
    let
      names = ev: builtins.attrNames (lib.filterAttrs (n: _: n != "_module") ev.options.glab);
    in
      names (evalHm {}) == names (evalDevenv {})
  );

  module-glab-devenv-installs-wrapper = mkTest "glab-devenv-installs-wrapper" (
    let
      ev = evalDevenv {
        glab = {
          enable = true;
          host.plain = "gitlab.example.com";
        };
      };
    in
      builtins.length ev.config.packages == 1
  );

  # The ONE intentional HM/devenv difference: devenv defaults configDir to
  # the project state dir, so a project-local glab does not mutate the
  # user's global ~/.config/glab-cli. It is a `config` default and NOT a
  # different option declaration, which is why the option-tree parity test
  # still holds — assert both halves so a later edit cannot quietly turn
  # this into a declaration difference.
  module-glab-configdir-facet-defaults = mkTest "glab-configdir-facet-defaults" (
    let
      base = {
        enable = true;
        host.plain = "gitlab.example.com";
      };
      hm = evalHm {glab = base;};
      dv = evalDevenv {glab = base;};
      overridden = evalDevenv {glab = base // {configDir = "/tmp/explicit";};};
    in
      hm.config.glab.configDir
      == null
      && dv.config.glab.configDir == "/tmp/devenv-state/glab-cli"
      # mkDefault, so a project can still point it elsewhere.
      && overridden.config.glab.configDir == "/tmp/explicit"
  );

  module-glab-codex-sandbox-grants-effective-configdir = mkTest "glab-codex-sandbox-grants-effective-configdir" (
    let
      base = {
        ai.codex = {
          enable = true;
          settings.sandbox_mode = "workspace-write";
        };
        glab = {
          enable = true;
          host.plain = "gitlab.example.com";
        };
      };
      hm = (evalHm base).config;
      devenv =
        (evalDevenv (lib.recursiveUpdate base {
          glab.configDir = "/home/test/.config/glab-cli";
        })).config;
    in
      builtins.elem
      "/home/test/.config/glab-cli"
      hm.ai.codex.settings.sandbox_workspace_write.writable_roots
      && builtins.elem
      "/home/test/.config/glab-cli"
      devenv.ai.codex.settings.sandbox_workspace_write.writable_roots
  );

  # Runtime test of the preflight, with a STUB standing in for glab so the
  # check needs no Go build. Covers what the wrapper does to the
  # filesystem before exec: create the config dir 0700, seed the hosts:
  # entry using the BARE hostname (scheme and path stripped), repair a
  # too-permissive config.yml to 0600, and then NOT re-seed.
  #
  # Behavior, not emitted text: a grep proving the line exists says
  # nothing about whether the shell actually does it.
  #
  # configDir is RELATIVE on purpose, so it lands in the build directory.
  # An absolute `/tmp/…` is not hermetic: Nix's per-build private /tmp is
  # a SANDBOX feature, and the sandbox is off by default on Darwin — one
  # of this repo's two CI platforms — so the test would touch (and
  # `rm -rf`) a shared host path. It also makes the `-d` assertions
  # stronger, since a leftover directory from an earlier run cannot
  # satisfy them.
  module-glab-preflight-runtime = let
    stub =
      (pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '')
      .overrideAttrs (_: {version = "0-test";});
    cfg = {
      enable = true;
      package = stub;
      configDir = "glab-preflight-cfg";
      host.plain = "https://gitlab.example.com/some/path";
      token.plain = "t0ken";
      job_token = null;
      settings = {};
      extraSettings = {};
    };
    wrapped = import ./../packages/glab/lib/mkGlab.nix {inherit lib pkgs cfg;};
  in
    pkgs.runCommand "module-test-glab-preflight-runtime" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      export HOME="$PWD/home"
      # Matches cfg.configDir above; the wrapper resolves it against the
      # build directory, which is this script's cwd.
      cfg=glab-preflight-cfg
      rm -rf "$cfg"
      export GLAB_STUB_LOG="$PWD/seed.log"
      : > "$GLAB_STUB_LOG"

      [ ! -d "$cfg" ] || {
        echo "FAIL: precondition — config dir already exists" >&2
        exit 1
      }

      ${wrapped}/bin/glab version >/dev/null

      mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$cfg")
      [ "$mode" = "700" ] || {
        echo "FAIL: config dir mode $mode, expected 700" >&2
        exit 1
      }

      grep -qxF -- 'config set --host gitlab.example.com api_protocol https' "$GLAB_STUB_LOG" || {
        echo "FAIL: seeding not invoked with the bare host + https. log:" >&2
        cat "$GLAB_STUB_LOG" >&2
        exit 1
      }

      printf 'hosts:\n  gitlab.example.com:\n' > "$cfg/config.yml"
      chmod 664 "$cfg/config.yml"
      ${wrapped}/bin/glab version >/dev/null
      mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$cfg/config.yml")
      [ "$mode" = "600" ] || {
        echo "FAIL: config.yml mode $mode after repair, expected 600" >&2
        exit 1
      }

      : > "$GLAB_STUB_LOG"
      ${wrapped}/bin/glab version >/dev/null
      if grep -q 'config set' "$GLAB_STUB_LOG"; then
        echo "FAIL: re-seeded although the hosts: entry was already present" >&2
        exit 1
      fi

      # The fast path must not FALSE-POSITIVE on a host differing only
      # where the dots are. This is the regression test for the pattern
      # matching the preflight must NOT go back to: as an ERE,
      # `gitlab.example.com` also matches `gitlab-example-com:`, so
      # seeding would be skipped while the real entry is absent — this
      # preflight's own bug, one layer down. The current implementation
      # compares fixed strings and has no such failure mode; this guards
      # against a future edit reintroducing pattern matching. A false
      # NEGATIVE is harmless here; a false positive is not.
      : > "$GLAB_STUB_LOG"
      printf 'hosts:\n  gitlab-example-com:\n' > "$cfg/config.yml"
      chmod 600 "$cfg/config.yml"
      ${wrapped}/bin/glab version >/dev/null
      grep -qF -- 'config set --host gitlab.example.com ' "$GLAB_STUB_LOG" || {
        echo "FAIL: a near-miss host suppressed seeding — the fast path is matching patterns, not fixed strings" >&2
        exit 1
      }

      echo PASS > "$out"
    '';

  # A bracketed IPv6 host must round-trip. The fast path used to be an
  # ERE with only `.` escaped, on the claim that hostnames are
  # [A-Za-z0-9.-]; `[` and `]` in an IPv6 literal either change the match
  # or make grep error, so the entry was never found and the wrapper
  # reseeded on every invocation. Now a fixed-string compare, which has no
  # escaping question at all.
  module-glab-ipv6-host-fast-path = let
    stub =
      (pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '')
      .overrideAttrs (_: {version = "0-test";});
    wrapped = import ./../packages/glab/lib/mkGlab.nix {
      inherit lib pkgs;
      cfg = {
        enable = true;
        package = stub;
        # Build-relative, for the reason given on
        # module-glab-preflight-runtime.
        configDir = "glab-ipv6-cfg";
        host.plain = "http://[2001:db8::1]/gitlab";
        token.plain = "t0ken";
        job_token = null;
        settings = {};
        extraSettings = {};
      };
    };
  in
    pkgs.runCommand "module-test-glab-ipv6-host-fast-path" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      export HOME="$PWD/home"
      export GLAB_STUB_LOG="$PWD/seed.log"
      # Bound once; must match cfg.configDir above.
      cfg=glab-ipv6-cfg
      rm -rf "$cfg"
      : > "$GLAB_STUB_LOG"

      # First run seeds, with the bracket host intact and http from scheme.
      ${wrapped}/bin/glab version >/dev/null
      grep -qF -- 'config set --host [2001:db8::1] api_protocol http' "$GLAB_STUB_LOG" || {
        echo "FAIL: IPv6 host not seeded correctly. log:" >&2
        cat "$GLAB_STUB_LOG" >&2
        exit 1
      }
      [ -d "$cfg" ] || {
        echo "FAIL: configDir $cfg was not created" >&2
        exit 1
      }

      # With the entry present, the fast path must MATCH and not reseed.
      # A pattern match could not: `[`/`]` are regex metacharacters.
      printf 'hosts:\n    [2001:db8::1]:\n' > "$cfg/config.yml"
      chmod 600 "$cfg/config.yml"
      : > "$GLAB_STUB_LOG"
      ${wrapped}/bin/glab version >/dev/null
      if grep -q 'config set' "$GLAB_STUB_LOG"; then
        echo "FAIL: reseeded despite the IPv6 entry being present" >&2
        cat "$GLAB_STUB_LOG" >&2
        exit 1
      fi

      echo PASS > "$out"
    '';

  # With configDir unset AND no HOME/XDG_CONFIG_HOME, the wrapper must
  # report what to set rather than dying on bash's bare
  # `HOME: unbound variable` from `set -u`. Reachable in practice: a tool
  # that REPLACES the environment (Claude Code's MCP `env` field) can
  # spawn this with no HOME at all.
  module-glab-preflight-no-home = let
    stub =
      (pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo "REACHED-PROGRAM"
      '')
      .overrideAttrs (_: {version = "0-test";});
    wrapped = import ./../packages/glab/lib/mkGlab.nix {
      inherit lib pkgs;
      cfg = {
        enable = true;
        package = stub;
        configDir = null;
        host.plain = "gitlab.example.com";
        token.plain = "t0ken";
        job_token = null;
        settings = {};
        extraSettings = {};
      };
    };
  in
    pkgs.runCommand "module-test-glab-preflight-no-home" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      if got=$(env -u HOME -u XDG_CONFIG_HOME -u GLAB_CONFIG_DIR \
                 ${wrapped}/bin/glab version 2>&1); then
        echo "FAIL: expected a non-zero exit with no HOME (got: $got)" >&2
        exit 1
      fi
      case "$got" in
        *"unbound variable"*)
          echo "FAIL: died on bash's unbound-variable error, not the guard: $got" >&2
          exit 1 ;;
        *"cannot locate a config directory"*) : ;;
        *)
          echo "FAIL: aborted, but not via the guard (got: $got)" >&2
          exit 1 ;;
      esac

      # The stub prints REACHED-PROGRAM, so assert it did not. The
      # non-zero check above already rules out "warned, then exec'd
      # successfully" — the stub exits 0, so that path would have made the
      # `if` fire. This closes the remaining gap: a guard that warns and
      # then reaches a program which itself fails. Without it the stub's
      # marker is a control nothing reads.
      case "$got" in
        *REACHED-PROGRAM*)
          echo "FAIL: guard fired but the program was still reached: $got" >&2
          exit 1 ;;
      esac

      echo PASS > "$out"
    '';

  # `api_protocol` must follow the scheme on the configured host rather
  # than being hardcoded https, or an http:// instance gets a config entry
  # contradicting how it is actually reached. Separate test because it
  # needs a differently-configured wrapper.
  module-glab-seeds-http-protocol = let
    stub =
      (pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' "$*" >> "''${GLAB_STUB_LOG:-/dev/null}"
      '')
      .overrideAttrs (_: {version = "0-test";});
    mkWrapped = cfgDir: hostValue:
      import ./../packages/glab/lib/mkGlab.nix {
        inherit lib pkgs;
        cfg = {
          enable = true;
          package = stub;
          configDir = cfgDir;
          host.plain = hostValue;
          token.plain = "t0ken";
          job_token = null;
          settings = {};
          extraSettings = {};
        };
      };
    # Build-relative, for the reason given on
    # module-glab-preflight-runtime.
    httpWrapped = mkWrapped "glab-proto-http" "http://gitlab.internal";
    bareWrapped = mkWrapped "glab-proto-bare" "gitlab.internal";
  in
    pkgs.runCommand "module-test-glab-seeds-http-protocol" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      export HOME="$PWD/home"
      export GLAB_STUB_LOG="$PWD/seed.log"

      # Must match the configDirs passed to mkWrapped above.
      httpCfg=glab-proto-http
      bareCfg=glab-proto-bare

      rm -rf "$httpCfg" "$bareCfg"
      : > "$GLAB_STUB_LOG"
      ${httpWrapped}/bin/glab version >/dev/null
      grep -qxF -- 'config set --host gitlab.internal api_protocol http' "$GLAB_STUB_LOG" || {
        echo "FAIL: http:// host was not seeded with api_protocol http. log:" >&2
        cat "$GLAB_STUB_LOG" >&2
        exit 1
      }
      # The configured dir must be the one actually created. Without this
      # a wrong configDir (e.g. a literal "$cfg" left by a bad refactor)
      # still satisfies the grep above, so the test would pass while
      # exercising the wrong path — which is exactly what deadnix caught.
      [ -d "$httpCfg" ] || {
        echo "FAIL: configDir $httpCfg was not created" >&2
        exit 1
      }

      # No scheme falls back to https, matching glab's own default.
      : > "$GLAB_STUB_LOG"
      ${bareWrapped}/bin/glab version >/dev/null
      grep -qxF -- 'config set --host gitlab.internal api_protocol https' "$GLAB_STUB_LOG" || {
        echo "FAIL: scheme-less host did not fall back to https. log:" >&2
        cat "$GLAB_STUB_LOG" >&2
        exit 1
      }
      [ -d "$bareCfg" ] || {
        echo "FAIL: configDir $bareCfg was not created" >&2
        exit 1
      }

      echo PASS > "$out"
    '';

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

  module-copilot-default-disabled = mkTest "copilot-default-disabled" (
    !(evalHm {}).config.ai.copilot.enable
    && !(evalDevenv {}).config.ai.copilot.enable
  );

  # `projectDir` remains discoverable with the same type/default in both module
  # trees, but only devenv has a project root. HM must diagnose an override
  # instead of silently interpreting it relative to HOME; devenv must consume
  # the same option for every project-native writer.
  module-copilot-project-dir-is-project-local = mkTest "copilot-project-dir-is-project-local" (
    let
      config.ai.copilot = {
        agents.reviewer = "Review the change.";
        context = "PROJECT-CONTEXT";
        enable = true;
        instructions = [
          {
            name = "named";
            text = "NAMED-INSTRUCTION";
          }
        ];
        projectDir = ".custom-github";
        rules.security.text = "SECURITY-RULE";
        skills.example = ./fixtures/claude-skills/skill-a;
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      builtins.any (assertion:
        !assertion.assertion
        && lib.hasInfix "project-local" assertion.message)
      hm.config.assertions
      && (devenv.config.files.".custom-github/copilot-instructions.md".text or "")
      == "PROJECT-CONTEXT"
      && lib.hasInfix "NAMED-INSTRUCTION"
      (devenv.config.files.".custom-github/instructions/named.instructions.md".text or "")
      && lib.hasInfix "SECURITY-RULE"
      (devenv.config.files.".custom-github/instructions/security.instructions.md".text or "")
      && lib.hasInfix "Review the change."
      (devenv.config.files.".custom-github/agents/reviewer.agent.md".text or "")
      && devenv.config.files.".custom-github/skills/example/SKILL.md".source
      == ./fixtures/claude-skills/skill-a/SKILL.md
      && !(devenv.config.files ? ".github/instructions/named.instructions.md")
      && !(devenv.config.files ? ".github/instructions/security.instructions.md")
  );

  module-kiro-default-disabled = mkTest "kiro-default-disabled" (
    !(evalHm {}).config.ai.kiro.enable
    && !(evalDevenv {}).config.ai.kiro.enable
  );

  module-all-four-enabled = mkTest "all-four-enabled" (
    let
      config = {
        ai = {
          claude.enable = true;
          codex.enable = true;
          copilot.enable = true;
          kiro.enable = true;
        };
      };
      hm = evalHm config;
      devenv = evalDevenv config;
    in
      hm.config.ai.claude.enable
      && hm.config.ai.codex.enable
      && hm.config.ai.copilot.enable
      && hm.config.ai.kiro.enable
      && devenv.config.ai.claude.enable
      && devenv.config.ai.codex.enable
      && devenv.config.ai.copilot.enable
      && devenv.config.ai.kiro.enable
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
  #
  # The heron_brook mitigation writes hooks into the same settings.json through
  # a DIFFERENT writer, so it must stay off here for this test to be about the
  # gap writer's own mkIf gate. That is now the default, so no explicit opt-out
  # is needed — but if delegationClamp ever becomes default-on again, this test
  # will start failing for a reason that has nothing to do with the gap writer.
  # `gitSshConfigWorkaround` is the second such writer and it IS default-on:
  # devenv has no `programs.git`, so the sandbox-safe SSH command reaches
  # Claude through `settings.env.GIT_SSH_COMMAND` — which makes settings
  # non-empty and would fail this test for a reason that has nothing to do
  # with the gap writer. Opted out here so the assertion stays about the
  # writer's own gate. The workaround's own delivery is covered by
  # `module-ai-git-ssh-default-follows-harnesses`.
  module-claude-devenv-settings-empty-no-gap-file = mkTest "claude-devenv-settings-empty-no-gap-file" (
    let
      result = evalDevenv {
        ai.claude.enable = true;
        ai.gitSshConfigWorkaround = false;
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

  # Kiro content pipeline: a credential http HEADER renders to a
  # `${env:VAR}` placeholder (Kiro expands it at launch) and a credential
  # URL to a bare `${VAR}` envsubst sentinel (WE expand it at activation)
  # — the raw secret file path is NEVER serialized, and the `Bearer `
  # header prefix + `https://` url prefix compose. Content-level (the
  # shared render both backends feed into). See mcpSecrets.nix.
  # ── Local credential-injecting proxy (lib/ai/mcpProxy.nix) ─────────
  # The property under test is NEGATIVE and easy to regress silently: a
  # proxied server must hand the client NOTHING secret. Assert the
  # loopback url is there AND that no header, no secret path, and no
  # placeholder survives into the entry.
  module-mcp-proxy-client-entry-drops-credentials = mkTest "mcp-proxy-client-entry-drops-credentials" (
    let
      entry = mcpProxyLib.clientEntry "example" proxySampleServer;
      json = builtins.toJSON entry;
    in
      entry.url
      == "http://127.0.0.1:9501/"
      && entry.type == "http"
      # `timeout` is client behavior, not a credential — it must survive.
      && entry.timeout == 300000
      # The fixture declares its credentials under `proxy.headers`, which
      # the daemon injects and the client never sees. Nothing from there
      # may appear in the entry.
      && !(entry ? headers)
      && !(lib.hasInfix "/run/secrets" json)
      && !(lib.hasInfix "Bearer" json)
      && !(lib.hasInfix "env:" json)
      && !(lib.hasInfix "X-Api-Key" json)
      && !(lib.hasInfix "X-Service-Token" json)
  );

  # Top-level `headers` on a proxied server are the CLIENT's and DO reach
  # it — that is the half of the split which makes the two keys mean
  # different things instead of one key meaning two. Dropping them here
  # would be a silent no-op on config the operator wrote.
  #
  # Safe only because `mkBackendTransform` asserts they carry no
  # credential; that assertion is tested separately below.
  module-mcp-proxy-client-entry-keeps-client-headers = mkTest "mcp-proxy-client-entry-keeps-client-headers" (
    let
      entry = mcpProxyLib.clientEntry "example" (proxySampleServer
        // {
          headers."X-Client-Sent" = "yes";
        });
    in
      entry.headers."X-Client-Sent"
      == "yes"
      # ... and still nothing the daemon injects.
      && !(lib.hasInfix "X-Api-Key" (builtins.toJSON entry))
  );

  # The Caddyfile lands in the WORLD-READABLE Nix store, so it may carry
  # only `{$VAR}` tokens. This also pins the escaping trap: Nix's `$${`
  # is an escape for a literal `${`, so a regression here silently emits
  # an unexpanded `{${VAR}}` that Caddy would forward verbatim.
  module-mcp-proxy-caddyfile-has-no-secrets = mkTest "mcp-proxy-caddyfile-has-no-secrets" (
    let
      cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer));
    in
      # `bind <host>` is the ONLY thing that restricts the listener to an
      # interface, and it is the assertion that matters most here: the
      # endpoint is unauthenticated, so a wildcard listener publishes use
      # of the upstream credential to the whole network.
      #
      # Do NOT weaken this to a site-address check like
      # `hasInfix "127.0.0.1:9501 {"`. That string is satisfied by a
      # config that still listens on every interface — in Caddy a site
      # address host is a Host-HEADER matcher, not a bind — so such a
      # test goes green on the insecure config. Measured.
      lib.hasInfix "bind 127.0.0.1" cf
      && lib.hasInfix "{$MCP_PROXY_EXAMPLE_X_SERVICE_TOKEN}" cf
      && lib.hasInfix "Bearer {$MCP_PROXY_EXAMPLE_X_API_KEY}" cf
      && lib.hasInfix "{$MCP_PROXY_EXAMPLE_ORIGIN}" cf
      && lib.hasInfix "{$MCP_PROXY_EXAMPLE_PATH}" cf
      # Plain-string headers are not secrets and stay literal.
      && lib.hasInfix ''header_up X-Route "primary"'' cf
      # Streaming: without this, SSE responses buffer to the end.
      && lib.hasInfix "flush_interval -1" cf
      # Caddy adds these four on its own and they must be deleted, not
      # merely overwritten. Measured — the `Via` header is NOT covered by
      # dropping the X-Forwarded-* trio.
      && lib.hasInfix "header_up -Via" cf
      && lib.hasInfix "header_up -X-Forwarded-For" cf
      && lib.hasInfix "header_up -X-Forwarded-Host" cf
      && lib.hasInfix "header_up -X-Forwarded-Proto" cf
      # A null `proxy.headers` value is a DELETION, not an injection.
      && lib.hasInfix "header_up -X-Drop-Me" cf
      && !(lib.hasInfix ''header_up X-Drop-Me "'' cf)
      # The proxy must NOT touch the client's identity. These were added
      # 2026-08-12 and removed 2026-08-13 after measurement: the headers
      # are undici defaults identifying Node, not a harness, and stripping
      # them made the request MORE distinctive. Asserted negatively so a
      # reintroduction has to argue with this comment first.
      && !(lib.hasInfix "header_up User-Agent" cf)
      && !(lib.hasInfix "header_up -Accept-Language" cf)
      && !(lib.hasInfix "header_up -Sec-Fetch-Mode" cf)
      # Go's transport adds `Accept-Encoding: gzip` below the header
      # layer, so no `header_up -` can reach it; only turning transport
      # compression off keeps the request identical to the client's.
      && lib.hasInfix "compression off" cf
      && !(lib.hasInfix "/run/secrets" cf)
      # The escape regression: an unexpanded Nix interpolation token.
      && !(lib.hasInfix "{\${" cf)
  );

  # Caddy's reverse_proxy ERROR logs embed the whole request header map,
  # and its built-in `log_credentials` covers only Authorization/Cookie —
  # never the custom auth headers this proxy injects. Measured 2026-08-12:
  # 35 journal lines carrying a live gateway API key.
  #
  # The fix drops the WHOLE MAP rather than naming secret fields. Asserted
  # that way on purpose: a per-field list is a denylist that fails OPEN on
  # any header nobody enumerated, so a test pinning field names would bless
  # exactly the shape being avoided.
  module-mcp-proxy-log-drops-whole-header-map = mkTest "mcp-proxy-log-drops-whole-header-map" (
    let
      cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer));
    in
      lib.hasInfix "format filter" cf
      && lib.hasInfix "request>headers delete" cf
      # No per-field redaction anywhere — that is the regression.
      && !(lib.hasInfix "request>headers>" cf)
  );

  # Unconditional: a proxy injecting no credential still drops headers. A
  # conditional filter would make the safe posture depend on the server's
  # shape, so ADDING a credential later would silently flip logging from
  # safe to leaky — the failure mode being designed out.
  module-mcp-proxy-log-drop-is-unconditional = mkTest "mcp-proxy-log-drop-is-unconditional" (
    let
      cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" {
        type = "http";
        url = "https://example.invalid/mcp";
        proxy = {
          enable = true;
          host = "127.0.0.1";
          port = 9501;
        };
      }));
    in
      lib.hasInfix "request>headers delete" cf
      && !(lib.hasInfix "format console" cf)
  );

  # A credential in a PROXIED server's top-level `headers` must be a hard
  # error, not an absorption. Those headers go to the client, so absorbing
  # them silently (the pre-2026-08-13 behavior) made one key mean two
  # things, and passing them through would hand the client the credential
  # the proxy exists to withhold. The assertion is also the migration
  # message for config written against the old shape.
  module-mcp-proxy-credential-in-client-headers-throws = mkTest "mcp-proxy-credential-in-client-headers-throws" (
    let
      result =
        builtins.tryEval
        (evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.jira = {
              type = "http";
              url.file = "/run/secrets/jira-url";
              # WRONG on purpose: belongs under proxy.headers.
              headers."X-Jira-Token".file = "/run/secrets/service-token";
              proxy = {
                enable = true;
                port = 9501;
              };
            };
          };
        })
      .config.assertions;
      failed =
        if result.success
        then builtins.filter (a: !a.assertion) result.value
        else [];
    in
      # Require the eval to SUCCEED and the failing assertion to be OURS.
      #
      # Accepting a throw here instead (`!result.success || …`) is what
      # this originally did, and it was wrong: `evalHm` returns
      # `config.assertions` WITHOUT checking them, so a failed assertion
      # never throws — the throw branch could only ever be reached by an
      # unrelated evaluation error, which it would then silently convert
      # into a pass. `tryEval` stays only so such an error surfaces as a
      # test failure rather than as an eval crash.
      result.success
      && builtins.any (a: lib.hasInfix "proxy.headers" a.message) failed
  );

  # A plain-string header on a proxied server is NOT a credential and must
  # keep working — the guard above has to reject secrets without rejecting
  # ordinary client config.
  module-mcp-proxy-literal-client-headers-allowed = mkTest "mcp-proxy-literal-client-headers-allowed" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          mcpServers.jira = {
            type = "http";
            url.file = "/run/secrets/jira-url";
            headers."X-Client-Sent" = "yes";
            proxy = {
              enable = true;
              port = 9501;
              headers."X-Jira-Token".file = "/run/secrets/service-token";
            };
          };
        };
      };
      failed = builtins.filter (a: !a.assertion) result.config.assertions;
    in
      builtins.all (a: !(lib.hasInfix "proxy.headers" a.message)) failed
  );

  # With no request headers in the logs, the UNIT is the only thing that
  # says which proxy a line came from. Without an explicit identifier the
  # visible one is the ExecStart store basename, whose hash changes on
  # every rebuild.
  module-mcp-proxy-unit-has-stable-syslog-identifier = mkTest "mcp-proxy-unit-has-stable-syslog-identifier" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          mcpServers.jira = {
            type = "http";
            url.file = "/run/secrets/jira-url";
            proxy = {
              enable = true;
              port = 9501;
              headers."X-Jira-Token".file = "/run/secrets/service-token";
            };
          };
        };
      };
      svc = result.config.systemd.user.services.mcp-proxy-jira.Service;
    in
      svc.SyslogIdentifier == "mcp-proxy-jira"
  );

  # Secrets must be read at RUNTIME from their files and never appear in
  # argv — /proc/<pid>/cmdline is world-readable, /proc/<pid>/environ is
  # not. Also pins the absolute-coreutils-path rule and fail-closed.
  module-mcp-proxy-start-script-reads-secrets-at-runtime = mkTest "mcp-proxy-start-script-reads-secrets-at-runtime" (
    let
      s = builtins.readFile (mcpProxyLib.startScriptFor (mcpProxyLib.specFor "example" proxySampleServer));
    in
      lib.hasInfix "/bin/cat \"/run/secrets/service-token\"" s
      && lib.hasInfix "export MCP_PROXY_EXAMPLE_X_SERVICE_TOKEN" s
      && lib.hasInfix "set -euETo pipefail" s
      && lib.hasInfix "shopt -s inherit_errexit" s
      # Fail closed: an empty or unreadable secret must not start a proxy
      # that would answer every client with the upstream's 401.
      && lib.hasInfix "resolved empty from" s
      && lib.hasInfix "the file is missing or unreadable" s
      # Never a bare `cat` — this wrapper can be spawned with no PATH.
      && !(lib.hasInfix "\ncat " s)
      # The secret must not be an ARGUMENT to caddy.
      && !(lib.hasInfix "--header" s)
  );

  module-kiro-mcp-secret-placeholders = mkTest "kiro-mcp-secret-placeholders" (
    let
      mcpJson = renderedMcpJson {
        jira = {
          type = "http";
          url = {
            file = "/run/secrets/jira-url";
            prefix = "https://";
          };
          timeout = 300000;
          headers = {
            "X-MCP-Servers" = "jira";
            "X-Jira-Token".file = "/run/secrets/service-token";
            "X-Api-Key" = {
              file = "/run/secrets/llm";
              prefix = "Bearer ";
            };
          };
        };
      };
    in
      lib.hasInfix "\${env:KIRO_MCP_JIRA_X_JIRA_TOKEN}" mcpJson
      && lib.hasInfix "Bearer \${env:KIRO_MCP_JIRA_X_API_KEY}" mcpJson
      && lib.hasInfix "https://\${KIRO_MCP_JIRA_URL}" mcpJson
      && lib.hasInfix ''"X-MCP-Servers":"jira"'' mcpJson
      && !(lib.hasInfix "/run/secrets/service-token" mcpJson)
      && !(lib.hasInfix "/run/secrets/llm" mcpJson)
      && !(lib.hasInfix "/run/secrets/jira-url" mcpJson)
  );

  # ONE credential shared by TWO servers. A gateway that multiplexes several
  # backends behind a single endpoint produces this: each server carries its
  # own token and a routing header, but they authenticate with the SAME api
  # key. The shared key must collapse to a SINGLE export rather than tripping
  # the collision guard — that guard rejects one var bound to two DIFFERENT
  # sources, which is not this case.
  module-kiro-mcp-secret-shared-across-servers = mkTest "kiro-mcp-secret-shared-across-servers" (
    let
      sharedKey = {
        file = "/run/secrets/gateway-key";
        prefix = "Bearer ";
        var = "GW_KEY";
      };
      mkServer = route: tokenFile: tokenVar: {
        type = "http";
        url = "https://gateway.example.com/mcp/";
        headers = {
          "X-Api-Key" = sharedKey;
          "X-Route" = route;
          "X-Token" = {
            file = tokenFile;
            var = tokenVar;
          };
        };
      };
      result = renderKiroSecrets {
        alpha = mkServer "alpha" "/run/secrets/alpha-token" "ALPHA_TOKEN";
        beta = mkServer "beta" "/run/secrets/beta-token" "BETA_TOKEN";
      };
      rendered = builtins.toJSON result.servers;
    in
      # The shared key deduped to one export, the per-server tokens stayed distinct.
      (builtins.attrNames result.secretEnv)
      == ["ALPHA_TOKEN" "BETA_TOKEN" "GW_KEY"]
      && result.secretEnv.GW_KEY.file == "/run/secrets/gateway-key"
      # Both servers reference that one var, with the prefix composed per-server.
      && (builtins.length (builtins.filter
        (lib.hasInfix "Bearer \${env:GW_KEY}")
        (map builtins.toJSON (builtins.attrValues result.servers))))
      == 2
      # Plain routing headers pass through untouched; no secret path is serialized.
      && lib.hasInfix ''"X-Route":"beta"'' rendered
      && !(lib.hasInfix "/run/secrets/" rendered)
  );

  # An explicit `var` is user-supplied and lands verbatim in generated shell
  # (`export <var>=…`, and the envsubst variable list), so an illegal shell
  # identifier must fail at EVAL rather than produce a broken activation
  # script at the moment secrets are materialized. A DERIVED name cannot hit
  # this — `sanitize` builds it — so only the explicit path needs the guard.
  module-kiro-mcp-secret-illegal-var-throws = mkTest "kiro-mcp-secret-illegal-var-throws" (
    let
      renders = var:
        builtins.tryEval (builtins.toJSON
          (renderKiroSecrets {
            a = {
              type = "http";
              url = "https://a.example.com/mcp/";
              headers."X-Key" = {
                file = "/run/secrets/one";
                inherit var;
              };
            };
          })
          .secretEnv);
    in
      # Hyphen, space, and a leading digit are all rejected...
      !(renders "my-key").success
      && !(renders "my key").success
      && !(renders "1KEY").success
      # ...while a legal identifier still goes through.
      && (renders "MY_KEY_1").success
  );

  # The collision guard genuinely fires: the SAME var bound to two DIFFERENT
  # files is ambiguous (silent last-wins would export the wrong secret), so it
  # must throw rather than pick one. Guards the dedup above from being widened
  # into "same name always wins".
  module-kiro-mcp-secret-var-collision-throws = mkTest "kiro-mcp-secret-var-collision-throws" (!(builtins.tryEval (builtins.toJSON
    (renderKiroSecrets {
      a = {
        type = "http";
        url = "https://a.example.com/mcp/";
        headers."X-Key" = {
          file = "/run/secrets/one";
          var = "SHARED";
        };
      };
      b = {
        type = "http";
        url = "https://b.example.com/mcp/";
        headers."X-Key" = {
          file = "/run/secrets/two";
          var = "SHARED";
        };
      };
    })
      .secretEnv))
    .success);

  # Kiro HM<->devenv parity: the SAME config yields the SAME rendered
  # mcp.json template on both backends (identical content -> identical
  # store path), each delivered as a REAL file (HM activation / devenv
  # enterShell anchored to $DEVENV_ROOT). Replaces the old home.file
  # symlink parity now that delivery is uniform real-file.
  module-kiro-hm-devenv-mcp-json-parity = mkTest "kiro-hm-devenv-mcp-json-parity" (
    let
      serversCfg = {
        jira = {
          type = "http";
          url.file = "/run/secrets/jira-url";
          headers."X-Jira-Token".file = "/run/secrets/service-token";
        };
      };
      cfg = {
        ai.kiro = {
          enable = true;
          mcpServers = serversCfg;
        };
      };
      hmScript = (evalHm cfg).config.home.activation.kiroMcpJson.text or "";
      dvScript = (evalDevenv cfg).config.enterShell or "";
      # Same content -> same store path on both backends. Strip the
      # string context: `lib.hasInfix` compiles the needle into a
      # `builtins.match` regex, which rejects a store-path context.
      templatePath = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" (renderedMcpJson serversCfg)}";
    in
      hmScript
      != ""
      && dvScript != ""
      && lib.hasInfix templatePath hmScript
      && lib.hasInfix templatePath dvScript
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' dvScript
  );

  # A credential-valued http header reaching the shared renderServer via a
  # non-Kiro path throws — non-Kiro ecosystems do not inject secret
  # headers (rather than serialize the raw file path). Forced via toJSON.
  module-mcp-credential-header-non-kiro-throws =
    mkTest "mcp-credential-header-non-kiro-throws" (!(builtins.tryEval (builtins.toJSON (mcpLib.renderServer pkgs "x" {
      type = "http";
      url = "u";
      headers.H.file = "/f";
    })))
    .success);

  # A credential-valued http URL reaching the shared renderServer via a
  # non-Kiro path throws (mirrors the header guard) — only Kiro assembles
  # a private mcp.json for a secret url.
  module-mcp-credential-url-non-kiro-throws =
    mkTest "mcp-credential-url-non-kiro-throws" (!(builtins.tryEval (builtins.toJSON (mcpLib.renderServer pkgs "x" {
      type = "http";
      url.file = "/f";
    })))
    .success);

  # Kiro HM: a secret url makes mcp.json a REAL-file activation write (NOT
  # a home.file symlink) that exports the url secret, envsubst's ONLY the
  # url var (header ${env:...} survive), and locks the file read-only
  # (overwrite default + secret url -> owner-only 0400).
  module-kiro-hm-mcp-json-activation-secret-url = mkTest "kiro-hm-mcp-json-activation-secret-url" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          mcpServers.jira = {
            type = "http";
            url.file = "/run/secrets/jira-url";
            headers."X-Jira-Token".file = "/run/secrets/service-token";
          };
        };
      };
      script = result.config.home.activation.kiroMcpJson.text or "";
    in
      !(result.config.home.file ? ".kiro/settings/mcp.json")
      && lib.hasInfix ''TARGET="$HOME/.kiro/settings/mcp.json"'' script
      && lib.hasInfix "/bin/envsubst '\${KIRO_MCP_JIRA_URL}'" script
      && lib.hasInfix "chmod 0400" script
      # The secret read must be a BARE assignment whose status errexit can
      # see, then a separate `export`. `export VAR="$(cmd)"` returns export's
      # status (always 0), so a failed read is silent and envsubst writes
      # `"url": ""`. This assertion previously required that exact broken
      # form, which is how the bug shipped.
      && lib.hasInfix ''KIRO_MCP_JIRA_URL="$('' script
      && !(lib.hasInfix ''export KIRO_MCP_JIRA_URL="$('' script)
      && lib.hasInfix "export KIRO_MCP_JIRA_URL\n" script
      # A secret file that exists but is EMPTY reads successfully, so length
      # is checked too rather than trusting the exit status alone.
      && lib.hasInfix ''if [ -z "''${KIRO_MCP_JIRA_URL}" ]; then'' script
      # Scoped: HM concatenates every activation entry into one script, so an
      # unscoped strict-mode header leaks into later entries and HM's own
      # code, and the exported SECRET would stay live for the rest of
      # activation.
      && lib.hasInfix "(\n  set -euETo pipefail" script
      && lib.hasSuffix ")\n" script
  );

  # Kiro HM: a plain (non-secret) http server still lands as a real-file
  # overwrite write — locked world-readable 0444, no envsubst step.
  module-kiro-hm-mcp-json-plain-overwrite = mkTest "kiro-hm-mcp-json-plain-overwrite" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          mcpServers.plain = {
            type = "http";
            url = "https://gw/mcp/";
          };
        };
      };
      script = result.config.home.activation.kiroMcpJson.text or "";
    in
      lib.hasInfix "chmod 0444" script
      && !(lib.hasInfix "envsubst" script)
      && !(result.config.home.file ? ".kiro/settings/mcp.json")
  );

  # Kiro HM: mcpWriteMode = "merge" deep-merges Nix servers onto the
  # on-disk file (jq '.[0] * .[1]', write-if-absent) and leaves it
  # writeable (0644) so hand edits survive.
  module-kiro-hm-mcp-json-merge-mode = mkTest "kiro-hm-mcp-json-merge-mode" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          mcpWriteMode = "merge";
          mcpServers.plain = {
            type = "http";
            url = "https://gw/mcp/";
          };
        };
      };
      script = result.config.home.activation.kiroMcpJson.text or "";
    in
      lib.hasInfix "'.[0] * .[1]'" script
      && lib.hasInfix "chmod 0644" script
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

  # The test above asserts the FILE is written — and it passed for the entire
  # life of a devenv module that never told copilot to read it. Copilot loads
  # MCP config from `$HOME/.copilot/mcp-config.json` or whatever
  # `--additional-mcp-config` points at, and NOTHING project-local: a syscall
  # trace of 1.0.78 in a project never even stats
  # `.config/github-copilot/mcp-config.json`. So writing the file is half the
  # job — and the half that matters here is that the flag points at the very
  # path the module rendered, which is why the needle is DERIVED from
  # `result.config.files` rather than spelled out.
  module-copilot-devenv-wrapper-points-at-project-mcp-config = let
    result = evalDevenv {
      ai.copilot.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
    name = "copilot-devenv-wrapper-points-at-project-mcp-config";
  in
    mkWrapperGrepTest {
      inherit name;
      package =
        lib.findFirst (p: (p.name or "") == "copilot-cli-wrapped")
        (throw "devenv produced no copilot-cli-wrapped package")
        result.config.packages;
      bin = "copilot";
      needles = [
        ''--additional-mcp-config @''${DEVENV_ROOT}/${mcpConfigKeyOf name result.config.files}''
      ];
    };

  # No MCP servers → no wrapper, so a project that configures none keeps the
  # bare package and pays for no rebuild.
  # Opts out of `gitSshConfigWorkaround` for the same reason as the Kiro
  # counterpart: on devenv it lands in `environmentVariables`, which is itself
  # a wrap trigger, and this test is about the MCP gate.
  module-copilot-devenv-unwrapped-without-mcp = mkTest "copilot-devenv-unwrapped-without-mcp" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.gitSshConfigWorkaround = false;
      };
    in
      !(lib.any (p: (p.name or "") == "copilot-cli-wrapped") result.config.packages)
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

  # environmentVariables → the launcher wrapper, on devenv exactly as on HM.
  # This used to assert devenv's native `env` blob; that wrote the PROJECT
  # SHELL, so the value also reached the developer's session.
  module-copilot-devenv-env-wrapper-populated = let
    result = evalDevenv {
      ai.copilot = {
        enable = true;
        environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
      };
    };
  in
    mkWrapperGrepTest {
      name = "copilot-devenv-env-wrapper-populated";
      package = builtins.head result.config.packages;
      bin = "copilot";
      needles = ["COPILOT_MODEL" "claude-sonnet-4"];
    };

  # Configuring MCP servers PRODUCES a wrapper. That is all this asserts: one
  # entry in home.packages, carrying the wrapped derivation's name.
  #
  # It was called `...-wrapper-injects-mcp-config-flag`, which claimed a great
  # deal more than it checked — nothing here reaches the flag, and the wrapper
  # shipped broken twice underneath a green result. The flag's VALUE is now
  # asserted by `module-copilot-hm-wrapper-points-at-mcp-config` below, and its
  # argv behavior by checks/copilot-wrapper-argv.nix. Deliberately NOT
  # strengthened: "the trigger produces a wrapper" is a real and separate
  # thing to know, and duplicating the other two would only make three tests
  # fail together.
  module-copilot-hm-mcp-servers-produce-wrapper = mkTest "copilot-hm-mcp-servers-produce-wrapper" (
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

  # The wiring counterpart on the HM side: the flag must point at the very
  # path this module rendered mcp-config.json to.
  #
  # The previous version of this test matched only `@''${HOME}/` — the PREFIX —
  # so it could not have caught a `configDir` change that moved the rendered
  # file out from under the flag. Deriving the needle from
  # `result.config.home.file` closes that: both ends move together, and only a
  # divergence fails.
  module-copilot-hm-wrapper-points-at-mcp-config = let
    result = evalHm {
      ai.copilot.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
    name = "copilot-hm-wrapper-points-at-mcp-config";
  in
    mkWrapperGrepTest {
      inherit name;
      package = builtins.head result.config.home.packages;
      bin = "copilot";
      needles = [
        ''--additional-mcp-config @''${HOME}/${mcpConfigKeyOf name result.config.home.file}''
      ];
    };

  # Configuring env vars PRODUCES a wrapper — the second, independent trigger.
  # Renamed from `...-wrapper-exports-env-vars`: it never observed an export.
  # That the values actually reach the process is asserted by
  # checks/copilot-wrapper-argv.nix, which runs the wrapper and reads its
  # environment.
  module-copilot-hm-env-vars-produce-wrapper = mkTest "copilot-hm-env-vars-produce-wrapper" (
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
      hookText = hmHookWriteScript result;
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
      # BOTH backends install the hook as a REAL file (kiro v3 skips symlinked
      # hooks — verified live on 2.13.0), and both now do it through the SHARED
      # materializer: HM via the activation pair, devenv via the
      # `ai:kiro:materialize-hooks` task. Parity is by construction (both lower
      # `mem.hooks."kiro-memory"` through `mkHookEntries`): assert each backend's
      # writer carries the generator output verbatim, byte-for-byte, via the same
      # heredoc-extraction idiom the steering half uses below.
      hmHook = hmHookWriteScript hm;
      dvHook = dvHookTaskExec dv;
      expectedHookBody =
        matLib.stripTrailingNewline
        (builtins.unsafeDiscardStringContext mem.hooks."kiro-memory");
      hmHookBody = matHeredocBody hmHook "kiro-memory.json";
      dvHookBody = matHeredocBody dvHook "kiro-memory.json";
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
      && hmHookBody == expectedHookBody
      && dvHookBody == expectedHookBody
      && lib.hasInfix ".kiro/hooks" hmHook
      && lib.hasInfix ".kiro/hooks" dvHook
      # The devenv task runs in the caller's cwd (direnv activates in
      # subdirectories), so the relative hook write must be anchored to
      # the project root.
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' dvHook
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

  # The `tui` option is GONE. It injected `--tui` and implied `--v3`; `--tui`
  # is redundant under v3 and is going away with it. Setting it must now be a
  # hard eval error, not a silently-ignored key — otherwise a stale consumer
  # config looks accepted while quietly losing the engine flag it depended on.
  module-kiro-hm-tui-option-removed = mkTest "kiro-hm-tui-option-removed" (!(builtins.tryEval
    (evalHm {
      ai.kiro = {
        enable = true;
        tui = true;
      };
    })
      .config
      .home
      .packages)
    .success);

  # devenv parity: v3 = true must wrap on devenv too, so `devenv shell` launches
  # the v3 engine like HM does (was HM-only before the shared wrapper). devenv
  # exports env natively, so the wrapper carries flags only — but the symlinkJoin
  # ("kiro-cli-wrapped") still fires on v3/tui alone.
  # The unlock must FORK the derivation — if the drvPath were unchanged, the
  # patch step silently did nothing and the consumer would get stock kiro while
  # believing workflows were on. Comparing drvPaths is the only assertion that
  # actually distinguishes those two worlds; a name check cannot, because both
  # sides are named `kiro-cli-wrapped`.
  module-kiro-hm-rollout-unlock-forks-package = mkTest "kiro-hm-rollout-unlock-forks-package" (
    let
      a =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        })
      .config
      .home
      .packages or [
        ];
      b =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        })
      .config
      .home
      .packages or [
        ];
    in
      soleFork a b
  );

  # devenv parity: same fork, same option, same backend-independent result.
  module-kiro-devenv-rollout-unlock-forks-package = mkTest "kiro-devenv-rollout-unlock-forks-package" (
    let
      a =
        kiroWrappedDrvs
        (evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        })
      .config
      .packages or [
        ];
      b =
        kiroWrappedDrvs
        (evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        })
      .config
      .packages or [
        ];
    in
      soleFork a b
  );

  # The default MUST leave the package untouched. This is what protects every
  # cachix hit: an unconditional patch step would fork the drvPath for every
  # consumer, including those who never asked for a dark-shipped feature.
  module-kiro-rollout-default-is-stock = mkTest "kiro-rollout-default-is-stock" (
    let
      packages = (evalHm {ai.kiro.enable = true;}).config.home.packages or [];
    in
      lib.any (p: (p.drvPath or null) == pkgs.ai.kiro-cli.drvPath) packages
  );

  # A duplicated entry must NOT fork the derivation — otherwise two configs
  # that mean the same thing produce two store paths and two 556 MB builds.
  module-kiro-rollout-dedupes-features = mkTest "kiro-rollout-dedupes-features" (
    let
      drvOf = features:
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = features;
          };
        })
        .config
        .home
        .packages or [
        ];
    in
      soleSame (drvOf ["workflows"]) (drvOf ["workflows" "workflows"])
      # Order must not fork it either. The list is comma-joined into
      # `postFixup`, so without a sort these two semantically identical sets
      # would produce different drvPaths and two redundant ~556 MB builds.
      && soleSame (drvOf ["tangent" "workflows"]) (drvOf ["workflows" "tangent"])
      # Control: a genuinely DIFFERENT set must still fork. Without this, the
      # two assertions above would also pass if canonicalization had collapsed
      # every input to a single derivation.
      && soleFork (drvOf ["workflows"]) (drvOf ["tangent" "workflows"])
  );

  # A `package` without the overlay's passthru cannot be patched. Assert the
  # failure is the NAMED one rather than a bare "attribute missing" pointing
  # into factory internals.
  module-kiro-rollout-rejects-package-without-passthru = mkTest "kiro-rollout-rejects-package-without-passthru" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          package = pkgs.hello;
          unlockedRolloutFeatures = ["workflows"];
        };
      };
      asserts =
        builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
        (ev.config.assertions or []);
    in
      asserts != [] && (builtins.head asserts).assertion == false
  );

  # Positive control for the above — the same assertion must PASS on the
  # overlay-provided package, or the negative proves only that it always fires.
  module-kiro-rollout-accepts-overlay-package = mkTest "kiro-rollout-accepts-overlay-package" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          unlockedRolloutFeatures = ["workflows"];
        };
      };
      asserts =
        builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
        (ev.config.assertions or []);
    in
      asserts != [] && (builtins.head asserts).assertion == true
  );

  # `unlockedRolloutFeatures` without `v3` is INERT, and silently so — the
  # binary really is patched, the option really is set, and the feature never
  # appears. The assertion is all that stands between a consumer and a
  # debugging session, so pin that it actually fires.
  module-kiro-rollout-requires-v3 = mkTest "kiro-rollout-requires-v3" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          unlockedRolloutFeatures = ["workflows"];
        };
      };
      asserts =
        builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
        (ev.config.assertions or []);
    in
      asserts != [] && (builtins.head asserts).assertion == false
  );

  # Positive control: the SAME assertion must pass once v3 is set, or the
  # negative above would hold equally for an assertion that always fires.
  module-kiro-rollout-v3-satisfies-assertion = mkTest "kiro-rollout-v3-satisfies-assertion" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          v3 = true;
          unlockedRolloutFeatures = ["workflows"];
        };
      };
      asserts =
        builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
        (ev.config.assertions or []);
    in
      asserts != [] && (builtins.head asserts).assertion == true
  );

  # Guards the sidecar wiring end to end: the option's enum is read from the
  # committed extraction, so an empty or malformed `rolloutFeatures` key would
  # otherwise surface only as a confusing type error at the consumer.
  module-kiro-rollout-enum-from-sidecar = mkTest "kiro-rollout-enum-from-sidecar" (
    let
      extracted = builtins.fromJSON (builtins.readFile ../overlays/kiro-cli-extracted.json);
    in
      lib.elem "workflows" extracted.rolloutFeatures
      && lib.elem "tangent" extracted.rolloutFeatures
      && builtins.length extracted.rolloutFeatures >= 6
  );

  # ── identity ───────────────────────────────────────────────────────────────
  # Same drvPath discipline as the rollout tests above, and for the same reason:
  # both sides are named `kiro-cli-wrapped`, so a name check cannot tell a
  # patched launcher from an unpatched one and would pass VACUOUSLY.
  module-kiro-hm-identity-forks-package = mkTest "kiro-hm-identity-forks-package" (
    let
      a =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        })
        .config
        .home
        .packages or [
        ];
      b =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            identity = "You are Atlas, a senior systems engineer.";
          };
        })
        .config
        .home
        .packages or [
        ];
    in
      soleFork a b
  );

  # devenv parity: the materializer is threaded through the SHARED
  # `resolveIdentityMaterializer`, so a fork here proves both backends wire it.
  module-kiro-devenv-identity-forks-package = mkTest "kiro-devenv-identity-forks-package" (
    let
      a =
        kiroWrappedDrvs
        (evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        })
        .config
        .packages or [
        ];
      b =
        kiroWrappedDrvs
        (evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            identity = "You are Atlas, a senior systems engineer.";
          };
        })
        .config
        .packages or [
        ];
    in
      soleFork a b
  );

  # The default must stay byte-identical to stock. An option that silently
  # wrapped every consumer would cost the cache hit it exists to preserve.
  module-kiro-identity-default-is-stock = mkTest "kiro-identity-default-is-stock" (
    let
      a =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
          };
        })
        .config
        .home
        .packages or [
        ];
      b =
        kiroWrappedDrvs
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            identity = null;
          };
        })
        .config
        .home
        .packages or [
        ];
    in
      soleSame a b
  );

  # The splice re-joins the preserved vendor text directly after the
  # replacement, so an identity that does not close its own final sentence
  # MERGES into it. Caught at EVAL rather than by the splicer's backstop,
  # because the splicer runs on a FAIL-OPEN launch path — a value rejected
  # there presents as "the identity silently did nothing", which is the exact
  # shape that let a multi-sentence identity ship broken.
  module-kiro-identity-requires-sentence-punctuation = mkTest "kiro-identity-requires-sentence-punctuation" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          v3 = true;
          identity = "You are Atlas, a senior systems engineer";
        };
      };
      asserts =
        builtins.filter (a: lib.hasInfix "must end with sentence punctuation" a.message)
        (ev.config.assertions or []);
    in
      asserts != [] && (builtins.head asserts).assertion == false
  );

  # Positive control: the same assertion must PASS on a punctuated value, and
  # on `!`/`?` as well as `.`. Without this the test above passes for a config
  # that fails every assertion, including for unrelated reasons.
  module-kiro-identity-punctuation-accepts-terminators = mkTest "kiro-identity-punctuation-accepts-terminators" (
    let
      failing = ident: let
        ev = evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            identity = ident;
          };
        };
      in
        builtins.filter
        (a: lib.hasInfix "must end with sentence punctuation" a.message && !a.assertion)
        (ev.config.assertions or []);
    in
      failing "You are Atlas, a senior systems engineer."
      == []
      && failing "You are Atlas! You judge silently." == []
      && failing "Are you sure about that?" == []
  );

  # ── workflow reminder ──────────────────────────────────────────────────────
  # AUTO means "on iff workflows is unlocked". All four corners of the tri-state
  # are pinned, because null/true/false is exactly where an off-by-default and
  # an on-by-default implementation look identical from any single test.
  module-kiro-workflow-reminder-auto-on-with-workflows = mkTest "kiro-workflow-reminder-auto-on-with-workflows" (
    let
      hooks =
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        })
        .config
        .ai
        .kiro
        .hooks;
    in
      hooks ? workflow-reminder
      && hooks.workflow-reminder.trigger == "UserPromptSubmit"
      # `agent` is the no-subprocess action: the short reminder is a static
      # string, so it needs no script and ignores timeout.
      && hooks.workflow-reminder.action.type == "agent"
      && hooks.workflow-reminder.action.prompt != null
  );

  module-kiro-workflow-reminder-absent-without-workflows =
    mkTest "kiro-workflow-reminder-absent-without-workflows" (!((evalHm {
      ai.kiro = {
        enable = true;
        v3 = true;
      };
    })
      .config
      .ai
      .kiro
      .hooks
      ? workflow-reminder));

  # Explicit `false` must beat the auto-on inference.
  module-kiro-workflow-reminder-forced-off =
    mkTest "kiro-workflow-reminder-forced-off" (!((evalHm {
      ai.kiro = {
        enable = true;
        v3 = true;
        unlockedRolloutFeatures = ["workflows"];
        workflowReminder.enable = false;
      };
    })
      .config
      .ai
      .kiro
      .hooks
      ? workflow-reminder));

  # Explicit `true` must beat the auto-off inference — the reminder is still
  # useful on a build where workflows were unlocked by some path other than
  # this option (KIRO_ENABLED_FEATURES, say).
  module-kiro-workflow-reminder-forced-on = mkTest "kiro-workflow-reminder-forced-on" (
    (evalHm {
      ai.kiro = {
        enable = true;
        v3 = true;
        workflowReminder.enable = true;
      };
    })
    .config
    .ai
    .kiro
    .hooks
    ? workflow-reminder
  );

  # The vendor-steering variant CANNOT be an `agent` action: its text lives in
  # the runtime-unpacked engine bundle, so it is not knowable at eval time and
  # has to shell out.
  module-kiro-workflow-reminder-vendor-steering-is-command = mkTest "kiro-workflow-reminder-vendor-steering-is-command" (
    let
      hook =
        (evalHm {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
            workflowReminder.includeVendorSteering = true;
          };
        })
        .config
        .ai
        .kiro
        .hooks
        .workflow-reminder;
    in
      hook.action.type == "command" && hook.action.command != null
  );

  # devenv parity for the reminder: same option, same contributed record.
  module-kiro-devenv-workflow-reminder-parity = mkTest "kiro-devenv-workflow-reminder-parity" (
    let
      hooks =
        (evalDevenv {
          ai.kiro = {
            enable = true;
            v3 = true;
            unlockedRolloutFeatures = ["workflows"];
          };
        })
        .config
        .ai
        .kiro
        .hooks;
    in
      hooks ? workflow-reminder && hooks.workflow-reminder.action.type == "agent"
  );

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

  # devenv parity for the removal: the option must be absent on both backends.
  module-kiro-devenv-tui-option-removed = mkTest "kiro-devenv-tui-option-removed" (!(builtins.tryEval
    (evalDevenv {
      ai.kiro = {
        enable = true;
        tui = true;
      };
    })
      .config
      .packages)
    .success);

  # devenv: with no v3/trust and no env, the package is installed RAW (the
  # shared wrapper returns the unwrapped derivation — no needless symlinkJoin).
  # Opts out of `gitSshConfigWorkaround`: on devenv that default reaches Kiro
  # through `environmentVariables`, which is itself a reason to wrap. Leaving
  # it on would make this pass or fail on the SSH default rather than on the
  # wrapper gate it exists to test.
  module-kiro-devenv-no-flags-no-wrap = mkTest "kiro-devenv-no-flags-no-wrap" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.gitSshConfigWorkaround = false;
      };
      packages = result.config.packages or [];
    in
      !(lib.any (p: (p.name or "") == "kiro-cli-wrapped") packages)
  );

  # HM: mcp.json — mergedServers deliver via a real-file activation write
  # (uniform real-file; no home.file symlink). Verify the activation
  # script exists and targets the mcp.json path.
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
      script = result.config.home.activation.kiroMcpJson.text or "";
    in
      script
      != ""
      && lib.hasInfix ".kiro/settings/mcp.json" script
      && !(result.config.home.file ? ".kiro/settings/mcp.json")
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
          v3 = true;
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

  # Explicit Kiro inclusion modes are carried by the shared instruction/rule
  # records, so the same config must render byte-identically in HM and devenv.
  # Paths remain available to other ecosystems but do not leak a
  # fileMatchPattern into Kiro when an explicit non-fileMatch mode wins.
  module-kiro-inclusion-modes-hm-devenv-parity = mkTest "kiro-inclusion-modes-hm-devenv-parity" (
    let
      config = {
        ai = {
          instructions = [
            {
              inclusion = "manual";
              name = "on-demand";
              paths = ["docs/**"];
              text = "Load only when requested.";
            }
          ];
          kiro.enable = true;
          rules.semantic = {
            description = "Semantic project guidance";
            inclusion = "auto";
            paths = ["src/**"];
            text = "Load when the description matches.";
          };
        };
      };
      hmSteering = (evalHm config).config.ai.kiro.steeringFiles;
      devenvSteering = (evalDevenv config).config.ai.kiro.steeringFiles;
      manual = (hmSteering."on-demand.md" or {}).text or "";
      auto = (hmSteering."semantic.md" or {}).text or "";
    in
      hmSteering."on-demand.md".text
      == devenvSteering."on-demand.md".text
      && hmSteering."semantic.md".text == devenvSteering."semantic.md".text
      && lib.hasInfix "inclusion: manual" manual
      && lib.hasInfix "inclusion: auto" auto
      && lib.hasInfix "description: Semantic project guidance" auto
      && !(lib.hasInfix "fileMatchPattern:" manual)
      && !(lib.hasInfix "fileMatchPattern:" auto)
  );

  module-kiro-inclusion-preserves-other-path-scopes = mkTest "kiro-inclusion-preserves-other-path-scopes" (
    let
      result = evalHm {
        ai = {
          claude.enable = true;
          codex.enable = true;
          copilot.enable = true;
          kiro.enable = true;
          rules.semantic = {
            description = "Semantic project guidance";
            inclusion = "auto";
            paths = ["src/**"];
            text = "Scoped guidance.";
          };
        };
      };
      claude = (result.config.home.file.".claude/rules/semantic.md" or {}).text or "";
      codex = (result.config.home.file.".codex/AGENTS.md" or {}).text or "";
      copilot = (result.config.home.file.".github/instructions/semantic.instructions.md" or {}).text or "";
      kiro = (result.config.ai.kiro.steeringFiles."semantic.md" or {}).text or "";
    in
      lib.hasInfix "paths:" claude
      && lib.hasInfix "src/**" claude
      && lib.hasInfix "Apply this guidance only" codex
      && lib.hasInfix "`src/**`" codex
      && lib.hasInfix ''applyTo: "src/**"'' copilot
      && lib.hasInfix "inclusion: auto" kiro
      && !(lib.hasInfix "fileMatchPattern:" kiro)
  );

  module-kiro-inclusion-invalid-enum-rejected = mkTest "kiro-inclusion-invalid-enum-rejected" (
    let
      instructionAttempt = builtins.tryEval (let
        result = evalHm {
          ai.instructions = [
            {
              inclusion = "sometimes";
              text = "Invalid";
            }
          ];
        };
      in
        builtins.deepSeq result.config.ai.instructions true);
      ruleAttempt = builtins.tryEval (let
        result = evalDevenv {
          ai.rules.invalid = {
            inclusion = "sometimes";
            text = "Invalid";
          };
        };
      in
        builtins.deepSeq result.config.ai.rules.invalid true);
    in
      !instructionAttempt.success && !ruleAttempt.success
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

  # HM: setting env vars PRODUCES a wrapper. Renamed from
  # `...-wrapper-exports-env-vars` — it never observed an export, only that the
  # installed package was the wrapped derivation. The export itself is asserted
  # behaviorally in checks/kiro-wrapper-argv.nix, which runs the wrapper and
  # reads `KIRO_WRAPPER_TEST` back out of the process.
  module-kiro-hm-env-vars-produce-wrapper = mkTest "kiro-hm-env-vars-produce-wrapper" (
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

  # HM: extraPackages creates a wrapper carrying the store-backed PATH prefix.
  module-kiro-hm-extra-packages-reach-wrapper = let
    result = evalHm {
      ai.kiro = {
        enable = true;
        extraPackages = [pkgs.which];
      };
    };
  in
    mkWrapperGrepTest {
      name = "kiro-hm-extra-packages-reach-wrapper";
      package = builtins.head result.config.home.packages;
      bin = "kiro-cli";
      needles = ["PATH" "${pkgs.which}/bin"];
    };

  # Devenv uses the same option and wrapper path as Home Manager.
  module-kiro-devenv-extra-packages-reach-wrapper = let
    result = evalDevenv {
      ai.kiro = {
        enable = true;
        extraPackages = [pkgs.which];
      };
    };
  in
    mkWrapperGrepTest {
      name = "kiro-devenv-extra-packages-reach-wrapper";
      package = builtins.head result.config.packages;
      bin = "kiro-cli";
      needles = ["PATH" "${pkgs.which}/bin"];
    };

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

  # A TYPED agent record lowers to JSON with `name` defaulted from the attr
  # key. That default is the whole point of the typed surface: Kiro's Rust CLI
  # REJECTS an agent file with no `name`, while the Node/ACP parser treats it
  # as optional — so an omission is invisible from the IDE and fatal on the
  # CLI. Also asserts null/empty fields are dropped, keeping the emitted file
  # to the minimal shape both parsers accept.
  module-kiro-typed-agent-defaults-name = mkTest "kiro-typed-agent-defaults-name" (
    let
      emitted = backend:
        builtins.fromJSON (backend {
          ai.kiro = {
            enable = true;
            agents.reviewer = {
              description = "Reviews diffs";
              prompt = "You review diffs.";
              tools = ["read" "shell"];
            };
          };
        });
      hmJson = emitted (cfg: (evalHm cfg).config.home.file.".kiro/agents/reviewer.json".text);
      devenvJson = emitted (cfg: (evalDevenv cfg).config.files.".kiro/agents/reviewer.json".text);
      wellFormed = j:
        j.name
        == "reviewer"
        && j.description == "Reviews diffs"
        && j.tools == ["read" "shell"]
        # null/empty optionals must not reach the file
        && !(j ? model)
        && !(j ? dispatchKind)
        && !(j ? resources)
        && !(j ? permissions);
    in
      wellFormed hmJson && wellFormed devenvJson && hmJson == devenvJson
  );

  # Pruning must reach INSIDE list elements. A permission rule declared without
  # `match`/`exclude` still carries their `[]` defaults, and a knowledge-base
  # resource its `include`/`exclude`. A pruner that only walks attrsets returns
  # the list untouched, so those empties reach the emitted file.
  module-kiro-typed-agent-prunes-in-lists = mkTest "kiro-typed-agent-prunes-in-lists" (
    let
      emitted =
        builtins.fromJSON
        (evalHm {
          ai.kiro = {
            enable = true;
            agents.scoped = {
              description = "d";
              permissions.rules = [
                {
                  capability = "shell";
                  effect = "deny";
                }
              ];
              resources = [
                {
                  type = "knowledgeBase";
                  source = "file:///docs";
                }
              ];
            };
          };
        })
        .config
        .home
        .file
        .".kiro/agents/scoped.json"
        .text;
      rule = builtins.head emitted.permissions.rules;
      resource = builtins.head emitted.resources;
    in
      rule.capability
      == "shell"
      && rule.effect == "deny"
      && !(rule ? match)
      && !(rule ? exclude)
      && resource.source == "file:///docs"
      && !(resource ? include)
      && !(resource ? exclude)
      && !(resource ? name)
  );

  # An explicit `name` overrides the attr-key default — Kiro keys the agent on
  # `name`, not on the filename, so this has to be reachable.
  module-kiro-typed-agent-explicit-name = mkTest "kiro-typed-agent-explicit-name" (
    let
      cfg =
        (evalHm {
          ai.kiro = {
            enable = true;
            agents.file-stem = {
              name = "explicit-id";
              description = "d";
            };
          };
        }).config;
    in
      (builtins.fromJSON cfg.home.file.".kiro/agents/file-stem.json".text).name
      == "explicit-id"
  );

  # Back-compat: a PATH-valued agent entry. Both backends must write the file
  # CONTENTS. devenv previously assigned the value straight to `files.*.text`,
  # which would have embedded the store path string as the file body (or
  # failed its `types.str` check) — the option type has always permitted a
  # path, and no test covered it, which is why the asymmetry survived.
  module-kiro-path-agent-both-backends = mkTest "kiro-path-agent-both-backends" (
    let
      mod = {
        ai.kiro = {
          enable = true;
          agents.from-file = ./fixtures/kiro-agent-raw.json;
        };
      };
      hmEntry = (evalHm mod).config.home.file.".kiro/agents/from-file.json";
      devenvEntry = (evalDevenv mod).config.files.".kiro/agents/from-file.json";
      # A path routes to `source` in BOTH backends, so neither stringifies it.
      resolves = e: (e.source or null) == ./fixtures/kiro-agent-raw.json;
    in
      resolves hmEntry && resolves devenvEntry
  );

  # `agents` and `agentsDir` are mutually exclusive; the assertion existed but
  # nothing exercised it.
  module-kiro-agents-dir-exclusive = mkTest "kiro-agents-dir-exclusive" (
    let
      cfg =
        (evalHm {
          ai.kiro = {
            enable = true;
            agents.reviewer = ''{"name":"reviewer"}'';
            agentsDir = ./fixtures/kiro-agents-dir;
          };
        }).config;
      failed = builtins.filter (a: !a.assertion) cfg.assertions;
    in
      builtins.length failed
      == 1
      && lib.hasInfix "cannot set both" (builtins.head failed).message
  );

  # `agentsDir` alone symlinks the directory wholesale (HM Layout B).
  module-kiro-agents-dir-symlinks = mkTest "kiro-agents-dir-symlinks" (
    let
      entry =
        (evalHm {
          ai.kiro = {
            enable = true;
            agentsDir = ./fixtures/kiro-agents-dir;
          };
        }).config.home.file.".kiro/agents";
    in
      entry.source == ./fixtures/kiro-agents-dir && entry.recursive
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
      hookScript = hmHookWriteScript result;
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
      t = hmHookWriteScript result;
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
      t = hmHookWriteScript result;
    in
      lib.hasInfix ''"command":"/nix/store'' t && lib.hasInfix "/bin/hello" t
  );

  # HM↔devenv: the same typed hook lands as a REAL file on both backends
  # (v3 skips symlinked hooks), through the shared materializer.
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
      dv = evalDevenv cfg;
      hmT = hmHookWriteScript (evalHm cfg);
      dvT = dvHookTaskExec dv;
    in
      lib.hasInfix ''"trigger":"PostToolUse"'' hmT
      && lib.hasInfix ''"trigger":"PostToolUse"'' dvT
      && lib.hasInfix "lint.json" dvT
      && lib.hasInfix ".kiro/hooks" dvT
      # relative hook write anchored to the project root (the task runs
      # in the caller's cwd).
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' dvT
      # NOT a devenv `files.*` symlink
      && !((dv.config.files or {}) ? ".kiro/hooks/lint.json")
      # the enterTest backstop asserts it landed as a real file
      && lib.hasInfix ".kiro/hooks/lint.json" (dv.config.enterTest or "")
  );

  # HM+devenv: records sharing a `file` co-locate into ONE envelope (N hooks in
  # one file — the typed path off the raw `hooksJson` escape hatch, e.g.
  # autoMemory's set in kiro-memory.json). A record without `file` keeps its own
  # <name>.json (back-compat); the Nix-only `file` key is stripped from output.
  # PR #433 moved HM hook delivery to home.activation real files (kiro v3 skips
  # store symlinks), so each envelope is read back out of its activation-script
  # heredoc body and structurally asserted via fromJSON — same strength as the
  # old home.file text read. The writer is now the SHARED materializer, so the
  # extraction uses `matHeredocBody` (content-hash-derived EOF marker) rather
  # than the retired fixed `NAT_KIRO_HOOK_EOF` delimiter.
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
      # inherits the whole string's context — which fromJSON rejects.
      # `matHeredocBody` strips it; byte content is unchanged.
      hmT =
        builtins.unsafeDiscardStringContext
        (hmHookWriteScript (evalHm cfg));
      hookBody = file: matHeredocBody hmT "${file}.json";
      coText = hookBody "kiro-memory";
      co = builtins.fromJSON coText;
      soloText = hookBody "solo";
      dvT = dvHookTaskExec (evalDevenv cfg);
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
      && lib.hasInfix "kiro-memory.json" dvT
      && !(lib.hasInfix "mem-stop.json" dvT)
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
      t = hmHookWriteScript result;
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

  # Hardening (PR #433 review): the HM hook writer prunes first, so a hook
  # removed or renamed in config stops firing. The prune is now the shared
  # materializer's manifest walk, not a whole-dir `*.json` glob — see the
  # ownership test below for why that distinction is load-bearing.
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
      prune = hmHookPruneScript ev;
    in
      lib.hasInfix "$NAT_MAT_MANIFEST" prune
      && lib.hasInfix "rm -f" prune
      && lib.hasInfix "set -euETo pipefail" prune
      # the CURRENT name is kept (it is rewritten by the write pass), so the
      # prune's keep-case must carry it
      && hasLiteral "demo.json) continue" prune
  );

  # THE DEFECT (N→0). The hook writers must exist whenever the module is
  # enabled — NOT gated on a non-empty hook set — so REMOVING THE LAST HOOK
  # still prunes. The previous writers carried their prune inside
  # `mkIf (hooks != {} || hooksJson != {})` / `mkIf (hooksDir != null)`, so
  # emptying the surface emitted nothing at all, the prune never ran, and
  # every previously written hook file stayed on disk and kept firing —
  # forever, since nothing else claims that directory. Both backends.
  module-kiro-hooks-empty-set-still-prunes = mkTest "kiro-hooks-empty-set-still-prunes" (
    let
      hm = evalHm {ai.kiro.enable = true;};
      prune = hmHookPruneScript hm;
      write = hmHookWriteScript hm;
      dv = evalDevenv {ai.kiro.enable = true;};
      task = (dv.config.tasks or {})."ai:kiro:materialize-hooks" or null;
    in
      # no hooks declared at all…
      hm.config.ai.kiro.hooks
      == {}
      && hm.config.ai.kiro.hooksJson == {}
      && hm.config.ai.kiro.hooksDir == null
      # …yet the prune pass is still emitted and still walks the manifest
      && lib.hasInfix "$NAT_MAT_MANIFEST" prune
      && lib.hasInfix "rm -f" prune
      && lib.hasInfix ".kiro/hooks" prune
      # …and the write pass still rewrites the manifest (to empty)
      && lib.hasInfix "NAT_MAT_NEW_MANIFEST" write
      # …and devenv keeps its task, for the same reason
      && task != null
      && lib.hasInfix "$NAT_MAT_MANIFEST" (task.exec or "")
      && lib.hasInfix ".kiro/hooks" (task.exec or "")
  );

  # THE TRAP the fix had to avoid. Making the OLD prune unconditional would
  # have made `rm -f "$HOOKS_DIR"/*.json` run on every activation for every
  # consumer who merely enables `ai.kiro` — deleting hand-placed hooks this
  # module never wrote. The materializer claims only the files it WROTE, so
  # the generated scripts must contain no whole-directory hook glob on
  # either backend.
  module-kiro-hooks-prune-is-manifest-scoped = mkTest "kiro-hooks-prune-is-manifest-scoped" (
    let
      cfg = {
        ai.kiro = {
          enable = true;
          hooksJson.demo = builtins.toJSON {
            version = "v1";
            hooks = [];
          };
        };
      };
      hm = evalHm cfg;
      scripts = [
        (hmHookPruneScript hm)
        (hmHookWriteScript hm)
        (dvHookTaskExec (evalDevenv cfg))
      ];
    in
      # no whole-directory hook glob anywhere in the generated shell…
      builtins.all (s: !(hasLiteral "*.json" s)) scripts
      # …deletion is driven by the manifest…
      && builtins.all (hasLiteral "$NAT_MAT_MANIFEST") scripts
      # …and the ONE declared non-manifest deletion class is the reserved
      # `.nat-tmp.` stale-temp sweep ([B8]), not a bare glob.
      && builtins.all (hasLiteral ".nat-tmp.") scripts
  );

  # The hooks and steering tasks share one materializer state directory and
  # devenv may run them concurrently. The lock is deliberately STATE-DIR-wide,
  # not per slug: every stale-temp sweep must exclude every other writer's live
  # manifest temp before it can delete the reserved `.nat-tmp.` namespace.
  # Prove both real generated tasks block behind that same lock, then release it
  # and run them concurrently to prove both surfaces and manifests survive.
  module-kiro-materializer-tasks-serialize-runtime = let
    ev = evalDevenv {
      ai.kiro = {
        enable = true;
        context = "SERIALIZED-STEERING-TOKEN.";
        hooksJson.demo = builtins.toJSON {
          version = "v1";
          hooks = [];
        };
      };
    };
    hookTask = pkgs.writeShellScript "kiro-hooks-lock-probe" (dvHookTaskExec ev);
    steeringTask = pkgs.writeShellScript "kiro-steering-lock-probe" (dvTaskExec ev);
  in
    pkgs.runCommand "module-test-kiro-materializer-tasks-serialize-runtime" {
      inherit hookTask steeringTask;
    } ''
      set -u
      fail() { echo "FAIL: kiro-materializer-tasks-serialize-runtime: $1" >&2; exit 1; }

      export DEVENV_ROOT="$TMPDIR/root"
      export DEVENV_STATE="$TMPDIR/state"
      state_dir="$DEVENV_STATE/nix-agentic-tools/materialize"
      ${pkgs.coreutils}/bin/mkdir -p "$DEVENV_ROOT" "$state_dir"

      exec 9> "$state_dir/lock"
      ${lib.getExe pkgs.flock} 9
      for probe in hookTask steeringTask; do
        task="''${!probe}"
        if ${pkgs.coreutils}/bin/timeout 1 "$task"; then
          fail "$probe ignored the shared materializer lock"
        else
          timeout_code=$?
        fi
        [ "$timeout_code" -eq 124 ] \
          || fail "$probe failed with $timeout_code instead of blocking on the lock"
      done
      ${lib.getExe pkgs.flock} -u 9
      exec 9>&-

      "$hookTask" &
      hook_pid=$!
      "$steeringTask" &
      steering_pid=$!
      wait "$hook_pid"
      wait "$steering_pid"

      [ -f "$DEVENV_ROOT/.kiro/hooks/demo.json" ] \
        || fail "hook task did not materialize demo.json"
      [ -f "$DEVENV_ROOT/.kiro/steering/AGENTS.md" ] \
        || fail "steering task did not materialize AGENTS.md"
      manifests=("$state_dir"/*.manifest)
      [ "''${#manifests[@]}" -eq 2 ] \
        || fail "concurrent tasks did not preserve both manifests"

      echo "PASS: kiro-materializer-tasks-serialize-runtime" > $out
    '';

  # RUNTIME proof of the two properties the string assertions above can only
  # approximate. Grepping generated bash cannot show that a file is actually
  # deleted or actually left alone, and both are the whole point of this
  # surface — so RUN the real writers across three generations, on BOTH
  # backends, against a sandbox HOME/DEVENV_ROOT:
  #
  #   gen 1: two hooks           → both materialize as real 0444 files
  #   gen 2: one hook            → the dropped hook is pruned
  #   gen 3: NO hooks at all     → the last hook is pruned (N→0, the defect)
  #
  # A hand-placed `handwritten.json` is planted after gen 1 and must survive
  # all of it (the ownership decision: this claims only what it wrote).
  #
  # `mkTest`'s eval-time assertion cannot express this, so it is a plain
  # runCommand. No strict-mode header: stdenv's setup.sh already sets all
  # four and phases share one shell (see the Bash standard's per-site table).
  module-kiro-hooks-materialize-runtime = let
    mkHook = command:
      builtins.toJSON {
        version = "v1";
        hooks = [
          {
            name = "probe";
            trigger = "Stop";
            action = {
              type = "command";
              inherit command;
            };
          }
        ];
      };
    genCfg = hooks: {
      ai.kiro = {
        enable = true;
        hooksJson = hooks;
      };
    };
    gens = [
      (genCfg {
        alpha = mkHook "alpha";
        beta = mkHook "beta";
      })
      (genCfg {alpha = mkHook "alpha";})
      (genCfg {})
    ];
    # HM delivers as a PAIR (prune entryBefore checkLinkTargets, write
    # entryAfter linkGeneration); replay them in that order.
    hmGen = cfg: let
      ev = evalHm cfg;
    in
      pkgs.writeShellScript "kiro-hooks-hm-gen"
      (hmHookPruneScript ev + "\n" + hmHookWriteScript ev);
    dvGen = cfg: pkgs.writeShellScript "kiro-hooks-dv-gen" (dvHookTaskExec (evalDevenv cfg));
  in
    pkgs.runCommand "module-test-kiro-hooks-materialize-runtime" {
      hmGens = map hmGen gens;
      dvGens = map dvGen gens;
    } ''
      set -u
      fail() { echo "FAIL: kiro-hooks-materialize-runtime: $1" >&2; exit 1; }

      run_backend() {
        backend="$1"
        hooks_dir="$2"
        shift 2

        gen1="$1"; gen2="$2"; gen3="$3"

        "$gen1"
        [ -f "$hooks_dir/alpha.json" ] || fail "$backend gen1: alpha.json missing"
        [ -f "$hooks_dir/beta.json" ] || fail "$backend gen1: beta.json missing"
        [ ! -L "$hooks_dir/alpha.json" ] || fail "$backend gen1: alpha.json is a symlink (v3 would skip it)"
        [ "$(${pkgs.coreutils}/bin/stat -c %a "$hooks_dir/alpha.json")" = 444 ] \
          || fail "$backend gen1: alpha.json is not the managed read-only mode"
        ${pkgs.gnugrep}/bin/grep -q '"command":"alpha"' "$hooks_dir/alpha.json" \
          || fail "$backend gen1: alpha.json content not materialized"

        # A hook this module never wrote. It must survive every later
        # generation — the old whole-dir `rm -f "$HOOKS_DIR"/*.json` ate it.
        echo '{"handwritten":true}' > "$hooks_dir/handwritten.json"

        "$gen2"
        [ -f "$hooks_dir/alpha.json" ] || fail "$backend gen2: alpha.json vanished"
        [ ! -e "$hooks_dir/beta.json" ] || fail "$backend gen2: removed hook beta.json still on disk"
        [ -f "$hooks_dir/handwritten.json" ] || fail "$backend gen2: unmanaged hook was deleted"

        # THE DEFECT: emptying the surface must still prune. Under the old
        # `mkIf`-gated writer this generation emitted nothing at all and
        # alpha.json kept firing forever.
        "$gen3"
        [ ! -e "$hooks_dir/alpha.json" ] || fail "$backend gen3: N->0 did not prune alpha.json"
        [ -f "$hooks_dir/handwritten.json" ] || fail "$backend gen3: unmanaged hook was deleted"
        ${pkgs.gnugrep}/bin/grep -q handwritten "$hooks_dir/handwritten.json" \
          || fail "$backend gen3: unmanaged hook was rewritten"
      }

      export HOME="$TMPDIR/hm-home"
      export XDG_STATE_HOME="$HOME/.local/state"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME"
      run_backend hm "$HOME/.kiro/hooks" $hmGens

      export DEVENV_ROOT="$TMPDIR/dv-root"
      export DEVENV_STATE="$TMPDIR/dv-state"
      ${pkgs.coreutils}/bin/mkdir -p "$DEVENV_ROOT" "$DEVENV_STATE"
      run_backend devenv "$DEVENV_ROOT/.kiro/hooks" $dvGens

      echo "PASS: kiro-hooks-materialize-runtime" > $out
    '';

  # Devenv: mcp.json write — real-file enterShell delivery (no files.*
  # symlink), anchored to $DEVENV_ROOT.
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
      script = result.config.enterShell or "";
    in
      lib.hasInfix ".kiro/settings/mcp.json" script
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' script
      && !(result.config.files ? ".kiro/settings/mcp.json")
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

  # Devenv: environment variables are baked into the launcher, not exported
  # into the project shell (which is what the old `env` blob did).
  module-kiro-devenv-env-wrapper-populated = let
    result = evalDevenv {
      ai.kiro = {
        enable = true;
        environmentVariables.KIRO_LOG_LEVEL = "debug";
      };
    };
  in
    mkWrapperGrepTest {
      name = "kiro-devenv-env-wrapper-populated";
      package = builtins.head result.config.packages;
      bin = "kiro-cli";
      needles = ["KIRO_LOG_LEVEL" "debug"];
    };

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

  # Devenv: hook files written as REAL files by the materialize task (kiro v3
  # does not discover symlinked hooks, so devenv `files.*` symlinks are wrong
  # here — the task writes a plain `.kiro/hooks/<name>.json`).
  module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          hooksJson.pre-commit = ''{"event": "pre-commit"}'';
        };
      };
      task = dvHookTaskExec result;
    in
      hasLiteral "nat_mat_write pre-commit.json" task
      && lib.hasInfix ''{"event": "pre-commit"}'' task
      && lib.hasInfix ".kiro/hooks" task
      # relative hook write anchored to the project root (the task runs
      # in the caller's cwd — direnv activates in subdirectories).
      && lib.hasInfix ''cd "$DEVENV_ROOT"'' task
      # not a devenv `files.*` symlink
      && !((result.config.files or {}) ? ".kiro/hooks/pre-commit.json")
      # the write is ordered before shell entry, and after devenv's own
      # files cleanup (same edge contract as the steering task)
      && ((result.config.tasks or {})."ai:kiro:materialize-hooks".after or [])
      == ["devenv:files:cleanup"]
  );

  # Devenv: the external `hooksDir` surface materializes the directory's
  # top-level `*.json` files into `.kiro/hooks/` as real files — same
  # v3-symlink rationale as the inline surface above, same project-root
  # anchoring, and now the SAME manifest, so flipping between the two
  # surfaces prunes the previous one instead of orphaning it.
  #
  # Also pins what is deliberately dropped vs. the retired `cp -rL`: a
  # subdirectory and a non-`.json` sibling in the fixture are BOTH ignored.
  # Kiro loads neither, and the retired whole-dir prune never removed
  # either — but the `.json` filter is additionally what keeps a dotfile
  # like `.gitkeep` from tripping the copy-mode name regex.
  module-kiro-devenv-hooks-dir-materializes = mkTest "kiro-devenv-hooks-dir-materializes" (
    let
      cfg = {
        ai.kiro = {
          enable = true;
          hooksDir = ./fixtures/kiro-hooks-dir;
        };
      };
      result = evalDevenv cfg;
      task = dvHookTaskExec result;
      hmWrite = hmHookWriteScript (evalHm cfg);
    in
      lib.hasInfix ''cd "$DEVENV_ROOT"'' task
      && hasLiteral "nat_mat_write sample.json" task
      && lib.hasInfix "hooks-dir-sample" task
      && lib.hasInfix ".kiro/hooks" task
      # HM parity — same entry, same writer, no second mechanism
      && lib.hasInfix "hooks-dir-sample" hmWrite
      # dropped: the subdirectory and the non-`.json` sibling are ignored
      && !(lib.hasInfix "nested" task)
      && !(lib.hasInfix "inner.json" task)
      && !(lib.hasInfix "ignore-me.txt" task)
      && !(lib.hasInfix "nested" hmWrite)
      && !(lib.hasInfix "ignore-me.txt" hmWrite)
      # real files, not devenv `files.*` symlinks
      && !(lib.any (n: lib.hasPrefix ".kiro/hooks/" n) (lib.attrNames (result.config.files or {})))
      # the enterTest backstop covers the dir surface too
      && lib.hasInfix ".kiro/hooks/sample.json" (result.config.enterTest or "")
  );

  # `hooksDir` unset again (N→0 for the DIR surface specifically): the writers
  # survive, so the files the previous generation copied out of that directory
  # are pruned rather than left firing. The old `mkIf (hooksDir != null)` gate
  # made this the exact case that leaked.
  module-kiro-hooks-dir-unset-still-prunes = mkTest "kiro-hooks-dir-unset-still-prunes" (
    let
      hm = evalHm {ai.kiro.enable = true;};
      dv = evalDevenv {ai.kiro.enable = true;};
      withDir = evalHm {
        ai.kiro = {
          enable = true;
          hooksDir = ./fixtures/kiro-hooks-dir;
        };
      };
    in
      # the dir surface really does produce a managed entry…
      hasLiteral "nat_mat_write sample.json" (hmHookWriteScript withDir)
      # …and with it back to null the prune pass is still emitted, on both
      # backends, still reading the manifest that recorded `sample.json`
      && hm.config.ai.kiro.hooksDir == null
      && lib.hasInfix "$NAT_MAT_MANIFEST" (hmHookPruneScript hm)
      && !(lib.hasInfix "sample.json" (hmHookWriteScript hm))
      && lib.hasInfix "$NAT_MAT_MANIFEST" (dvHookTaskExec dv)
      && !(lib.hasInfix "sample.json" (dvHookTaskExec dv))
  );

  # A `hooksDir` filename that is unsafe to interpolate into the generated
  # shell must fail at EVAL. `hookNameAssertion` covers only the inline
  # surfaces' attr keys, so without the materializer's entry assertions the
  # dir surface had no name guard at all.
  module-kiro-hooks-dir-rejects-unsafe-filename = mkTest "kiro-hooks-dir-rejects-unsafe-filename" (
    let
      ev = evalHm {
        ai.kiro = {
          enable = true;
          hooksDir = ./fixtures/kiro-hooks-dir-unsafe;
        };
      };
      nameAsserts =
        builtins.filter (a: lib.hasInfix "copy-strategy hook file names must match" a.message)
        (ev.config.assertions or []);
    in
      nameAsserts != [] && (builtins.head nameAsserts).assertion == false
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
  # module now installs the (unprefixed) stack-* skills + skill-routing rule
  # user-global; the devenv module mirrors them project-local. References are
  # bundled as REAL files inside each skill dir (deref'd at build).

  # Default disabled — stacked-workflows.enable defaults to false.
  module-sws-default-disabled = mkTest "sws-default-disabled" (
    let
      result = evalHm {};
    in
      !(result.config.stacked-workflows.enable or true)
  );

  # ── Where these contributions land ────────────────────────────────────
  #
  # The skill packages write the PER-RUNTIME pools (`ai.<runtime>.skills`,
  # `ai.<runtime>.instructions`), never the root ones. The tests below assert
  # both halves of that, and the second half is the one worth having: a root
  # pool is ADDITIVE and cannot be retracted per runtime, so a regression that
  # moved these writes back to the root would still deliver every skill to
  # every runtime and pass a presence-only test.
  #
  # They iterate `harnessNames` (the shared registry) rather than sampling one
  # runtime, so a sixth runtime is covered the day it is added.

  # Devenv scope: enable -> every runtime's pool gets the unprefixed stack-*
  # skills, and the root pool gets none of them.
  module-sws-devenv-enable-sets-ai-skills = mkTest "sws-devenv-enable-sets-ai-skills" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      expected = ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"];
      runtimeHasAll = runtime:
        lib.all (skill: result.config.ai.${runtime}.skills ? ${skill}) expected;
    in
      lib.all runtimeHasAll harnessNames
      && !(result.config.ai.skills ? stack-fix)
  );

  # Devenv scope: the router instruction landed in every runtime's pool, once
  # each, and not in the root pool.
  module-sws-devenv-enable-sets-ai-instructions = mkTest "sws-devenv-enable-sets-ai-instructions" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      swsEntries = instructions:
        builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
      runtimeHasOne = runtime:
        builtins.length (swsEntries result.config.ai.${runtime}.instructions) == 1;
    in
      lib.all runtimeHasOne harnessNames
      && swsEntries result.config.ai.instructions == []
  );

  # HM (user-global) scope: enable -> every runtime's pool gets the unprefixed
  # stack-* skills, so each enabled CLI installs them to ~/.claude/skills etc.
  # This is the scope-revert (previously the HM module was git-config only).
  module-sws-hm-enable-sets-ai-skills = mkTest "sws-hm-enable-sets-ai-skills" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      expected = ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"];
      runtimeHasAll = runtime:
        lib.all (skill: result.config.ai.${runtime}.skills ? ${skill}) expected;
    in
      lib.all runtimeHasAll harnessNames
      && !(result.config.ai.skills ? stack-fix)
  );

  # HM (user-global) scope: enable -> the skill-routing instruction lands in
  # every runtime's pool (-> ~/.claude/CLAUDE.md, ~/.kiro/steering/, ...).
  module-sws-hm-enable-sets-ai-instructions = mkTest "sws-hm-enable-sets-ai-instructions" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      swsEntries = instructions:
        builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
      runtimeHasOne = runtime:
        builtins.length (swsEntries result.config.ai.${runtime}.instructions) == 1;
    in
      lib.all runtimeHasOne harnessNames
      && swsEntries result.config.ai.instructions == []
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
      skillPath = result.config.ai.claude.skills.stack-fix;
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

  # HM (primary): enable -> ai.<runtime>.skills.living-workflow -> upstream
  # programs.claude-code.skills.living-workflow (end-to-end fanout). This is the
  # test that proves the per-runtime write still REACHES emission; the pool
  # assertions above only prove where the value landed.
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

  # Devenv parity: enable in the devenv module contributes the skill to every
  # runtime's pool too (config-parity rule; separate eval from HM), and leaves
  # the root pool alone.
  module-living-workflow-devenv-enable-sets-skill = mkTest "living-workflow-devenv-enable-sets-skill" (
    let
      result = evalDevenv {living-workflow.enable = true;};
    in
      lib.all (runtime: result.config.ai.${runtime}.skills ? living-workflow) harnessNames
      && !(result.config.ai.skills ? living-workflow)
  );

  # Disabled -> absent: with living-workflow off, no living-workflow skill is
  # contributed even when an ecosystem is enabled.
  #
  # This asserts the PER-RUNTIME pools specifically. Pointing it at the root
  # pool would make it vacuous now that nothing writes there — it would pass
  # for a module that was deleted outright as readily as for one that is
  # correctly gated on `enable`.
  module-living-workflow-disabled-no-skill = mkTest "living-workflow-disabled-no-skill" (
    let
      result = evalHm {ai.kiro.enable = true;};
    in
      lib.all (runtime: !(result.config.ai.${runtime}.skills ? living-workflow)) harnessNames
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
      #
      # A line counts as wrapped when it STARTS with `run ` (the standalone
      # commands) or pipes into it (the tee write). Testing for a bare `run `
      # infix instead would be satisfied by an unrelated `--dry-run ` token on
      # the same line, which is a false pass rather than a stylistic nit.
      lstrip = l: let
        m = builtins.match "[[:space:]]*(.*)" l;
      in
        if m == null
        then l
        else builtins.head m;
      runWrapped = l: lib.hasPrefix "run " (lstrip l) || lib.hasInfix "| run --quiet " l;
      # UNIVERSALLY quantified, and that is the whole point. An existential
      # ("SOME line is wrapped") passes while an UNWRAPPED mutating command
      # sits beside a wrapped one, so reintroducing the defect next to the fix
      # would leave this green and DRY_RUN mutating again. `hits != []` is the
      # positive control that stops the `all` passing vacuously when a
      # fragment stops appearing at all -- without it, DELETING a command
      # would look like compliance.
      everyOccurrenceWrapped = frag: let
        hits = lib.filter (l: lib.hasInfix frag l) lines;
      in
        hits != [] && lib.all runWrapped hits;
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
        everyOccurrenceWrapped "/bin/mkdir -p"
        && everyOccurrenceWrapped "/bin/chmod 700"
        && everyOccurrenceWrapped "/bin/systemctl --user restart"
        && everyOccurrenceWrapped "/bin/tee -- \"$hash_file\""
        # The read-only `is-active` probe must stay UNWRAPPED: a dry run has
        # to evaluate its conditions to report accurately. Asserted so the
        # rule above is not "over-applied" into wrapping reads as well.
        && lib.any (l: lib.hasInfix "/bin/systemctl --user is-active" l && !(runWrapped l)) lines
        # ANY redirection at the hash file, whatever the spacing. A plain
        # substring test for the exact `> "$hash_file"` form matched only that
        # one spelling, so `>"$hash_file"` -- valid shell, identical effect --
        # walked straight through the assertion meant to forbid it. Matching
        # `>` followed by optional whitespace covers the no-space, extra-space
        # and append spellings alike.
        && !(lib.any (l: builtins.match ".*>[[:space:]]*\"\\$hash_file\".*" l != null) lines)
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

  # ── service.host must reach the actual bind ────────────────────────
  #
  # `service.host` reads as a security control and defaults to loopback, but
  # for openmemory it was declared, documented, and then silently discarded:
  # settingsToEnv emitted OM_PORT and nothing else, and upstream's daemon
  # calls `listen(port)` with no host, so it bound every interface. A running
  # instance was reachable over both LAN IPv4 and a routable global IPv6
  # address, unauthenticated. The overlay patches OM_HOST in (see
  # overlays/mcp-servers/openmemory-mcp.nix); these assert the module
  # actually emits it.
  module-mcp-services-openmemory-binds-loopback-by-default = mkTest "mcp-services-openmemory-binds-loopback-by-default" (
    let
      result = evalHm {
        services.mcp-servers.servers.openmemory-mcp.enable = true;
      };
      env = result.config.systemd.user.services.mcp-openmemory-mcp.Service.Environment or [];
      omHost = lib.findFirst (lib.hasPrefix "OM_HOST=") null env;
    in
      omHost != null && lib.hasInfix "127.0.0.1" omHost
  );

  # ...and that it still follows an explicit opt-in to a wider bind, so the
  # option is a real knob rather than a hardcoded loopback.
  module-mcp-services-openmemory-host-override = mkTest "mcp-services-openmemory-host-override" (
    let
      result = evalHm {
        services.mcp-servers.servers.openmemory-mcp = {
          enable = true;
          service.host = "0.0.0.0";
        };
      };
      env = result.config.systemd.user.services.mcp-openmemory-mcp.Service.Environment or [];
      omHost = lib.findFirst (lib.hasPrefix "OM_HOST=") null env;
    in
      omHost != null && lib.hasInfix "0.0.0.0" omHost
  );

  # Bridge servers run mcp-proxy, whose own --host default IS loopback — so
  # they were already safe, but by upstream happenstance rather than by
  # anything stated here, and service.host was discarded for all ten of
  # them. Assert we PIN it, so an upstream default change cannot silently
  # widen every bridge service at once.
  module-mcp-services-bridge-pins-bind-host = let
    # 127.0.0.2 is deliberately NOT mcp-proxy's own default (127.0.0.1), so a
    # match proves the value was threaded from service.host rather than merely
    # inherited from upstream — which is the entire point of pinning it.
    overridden = evalHm {
      services.mcp-servers.servers.context7-mcp = {
        enable = true;
        service.host = "127.0.0.2";
      };
    };
    defaulted = evalHm {
      services.mcp-servers.servers.context7-mcp.enable = true;
    };
    execOf = r: r.config.systemd.user.services.mcp-context7-mcp.Service.ExecStart;
    # Build the expected fragment with the SAME escaper the emitter uses, so
    # the two cannot disagree. Today `lib.escapeShellArg` leaves a dotted quad
    # bare (it only quotes strings outside `[[:alnum:],._+:@%/-]+`), so this
    # renders `--host 127.0.0.2` — but hardcoding either the bare or the
    # quoted form would turn a future change in that rule into a test failure
    # against a wrapper that is still correct.
    expectHost = h: lib.escapeShellArg "--host ${lib.escapeShellArg h}";
  in
    pkgs.runCommand "module-test-mcp-services-bridge-pins-bind-host" {} ''
      fail() {
        echo "FAIL: mcp-services-bridge-pins-bind-host: $1" >&2
        exit 1
      }
      o=${execOf overridden}
      d=${execOf defaulted}
      grep -qF -- '--host' "$d" || fail "mcp-proxy invoked without --host at all"
      grep -qF -- ${expectHost "127.0.0.2"} "$o" \
        || fail "bind host not threaded from an overridden service.host"
      grep -qF -- ${expectHost "127.0.0.1"} "$d" \
        || fail "default bind host is not loopback"
      grep -qF -- 'context7-mcp --transport stdio' "$o" \
        || fail "context7 bridge does not launch its working stdio transport"
      if grep -qF -- 'context7-mcp --transport stdio --port' "$o"; then
        fail "context7 bridge passes the proxy port to its stdio child"
      fi
      if grep -qF -- 'context7-mcp --transport http' "$o"; then
        fail "context7 bridge still launches its Upstash-only native HTTP transport"
      fi
      echo PASS > "$out"
    '';

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

  # HM: top-level ai.environmentVariables fans out to the Kiro wrapper.
  #
  # This asserted only that A wrapper appeared, which cannot tell "the
  # top-level value fanned out" apart from "some other trigger wrapped the
  # package" — the fanout, the thing the name promises, went unobserved. HM has
  # no native env surface (the wrapper IS the delivery mechanism), so the value
  # has to be read back out of the shipped script.
  #
  # The sentinel is deliberately distinctive: `grep -F bar` would match store
  # paths incidentally and pass without the fanout ever happening.
  module-kiro-hm-top-level-env-fanout = let
    result = evalHm {
      ai.kiro.enable = true;
      ai.environmentVariables.KIRO_FOO = "kiro-hm-fanout-sentinel";
    };
  in
    mkWrapperGrepTest {
      name = "kiro-hm-top-level-env-fanout";
      package = builtins.head result.config.home.packages;
      bin = "kiro-cli";
      needles = ["KIRO_FOO" "kiro-hm-fanout-sentinel"];
    };

  # Devenv: top-level ai.environmentVariables fans to the Kiro wrapper.
  module-kiro-devenv-top-level-env-fanout = let
    result = evalDevenv {
      ai.kiro.enable = true;
      ai.environmentVariables.KIRO_DEBUG = "kiro-devenv-fanout-sentinel";
    };
  in
    mkWrapperGrepTest {
      name = "kiro-devenv-top-level-env-fanout";
      package = builtins.head result.config.packages;
      bin = "kiro-cli";
      needles = ["KIRO_DEBUG" "kiro-devenv-fanout-sentinel"];
    };

  # HM: top-level ai.environmentVariables fans out to the Copilot wrapper.
  # Same reasoning as the Kiro counterpart above — the value, not merely the
  # wrapper's existence, is what the name promises.
  module-copilot-hm-top-level-env-fanout = let
    result = evalHm {
      ai.copilot.enable = true;
      ai.environmentVariables.COPILOT_FOO = "copilot-hm-fanout-sentinel";
    };
  in
    mkWrapperGrepTest {
      name = "copilot-hm-top-level-env-fanout";
      package = builtins.head result.config.home.packages;
      bin = "copilot";
      needles = ["COPILOT_FOO" "copilot-hm-fanout-sentinel"];
    };

  # Devenv: top-level ai.environmentVariables fans to the Copilot wrapper.
  module-copilot-devenv-top-level-env-fanout = let
    result = evalDevenv {
      ai.copilot.enable = true;
      ai.environmentVariables.COPILOT_DEBUG = "copilot-devenv-fanout-sentinel";
    };
  in
    mkWrapperGrepTest {
      name = "copilot-devenv-top-level-env-fanout";
      package = builtins.head result.config.packages;
      bin = "copilot";
      needles = ["COPILOT_DEBUG" "copilot-devenv-fanout-sentinel"];
    };

  # Devenv: per-CLI ai.kiro.environmentVariables wins over top-level on name
  # collision. `absentNeedles` is the half that matters — the wrapper baking
  # BOTH values would satisfy a presence-only check while leaving which one
  # actually wins undetermined.
  module-kiro-devenv-per-cli-env-wins = let
    result = evalDevenv {
      ai = {
        kiro.enable = true;
        environmentVariables.SHARED = "top-level-loser";
        kiro.environmentVariables.SHARED = "kiro-specific-winner";
      };
    };
  in
    mkWrapperGrepTest {
      name = "kiro-devenv-per-cli-env-wins";
      package = builtins.head result.config.packages;
      bin = "kiro-cli";
      needles = ["SHARED" "kiro-specific-winner"];
      absentNeedles = ["top-level-loser"];
    };

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

  module-copilot-hm-path-agent-resolves-to-text = mkTest "copilot-hm-path-agent-resolves-to-text" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.agents.reviewer = ./fixtures/claude-agents/agent-one.md;
      };
      agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
    in
      agentFile
      != null
      && (agentFile.text or null) == builtins.readFile ./fixtures/claude-agents/agent-one.md
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

  # Kiro independence: the top-level `ai.agents` pool carries Claude/Copilot
  # tool NAMES, while Kiro's typed record takes capability TAGS — different
  # vocabularies, so there is no pass-through lowering. Setting ai.agents.foo
  # when ai.kiro.enable = true must NOT produce a .kiro/agents/foo file.
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

  # ── heron_brook delegation clamp (ai.claude.delegationClamp) ──────
  # OPT-IN is the requirement: a bare `enable = true` must carry NEITHER hook.
  # Asserting both are absent also pins the all-or-nothing property — emitting
  # only the PreCompact half would leave a hook clearing a marker nothing ever
  # writes, inert but confusing to find in a settings.json you never asked to
  # be modified.
  module-claude-hm-delegation-clamp-default-off = mkTest "claude-hm-delegation-clamp-default-off" (
    let
      result = evalHm {ai.claude.enable = true;};
      settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
    in
      (settingsHooks.UserPromptSubmit or [])
      == []
      && (settingsHooks.PreCompact or []) == []
  );

  # Opting in must produce BOTH hooks: the injector and the PreCompact re-arm.
  # Compaction is the one event that erases the injected context, so an injector
  # without the re-arm silently loses the mitigation on the first compaction.
  module-claude-hm-delegation-clamp-opt-in = mkTest "claude-hm-delegation-clamp-opt-in" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          delegationClamp.mitigate = true;
        };
      };
      settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
    in
      hasClampHook (settingsHooks.UserPromptSubmit or [])
      && hasClampHook (settingsHooks.PreCompact or [])
  );

  # Devenv parity — same two hooks behind the same flag, per the config-parity rule.
  module-claude-devenv-delegation-clamp-opt-in = mkTest "claude-devenv-delegation-clamp-opt-in" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          delegationClamp.mitigate = true;
        };
      };
      settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
    in
      hasClampHook (settingsJson.hooks.UserPromptSubmit or [])
      && hasClampHook (settingsJson.hooks.PreCompact or [])
  );

  # Compose-not-clobber. The mitigation is emitted as a DEFINITION of
  # ai.claude.hooks, never as that option's `default` — a default is discarded
  # wholesale the moment a consumer defines the option at all, which would have
  # silently disabled the mitigation for exactly the consumers who use hooks most.
  # This test is what pins that choice down.
  module-claude-delegation-clamp-composes-with-consumer-hook = mkTest "claude-delegation-clamp-composes-with-consumer-hook" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          delegationClamp.mitigate = true;
          hooks.UserPromptSubmit = [{hooks = [{command = "consumer-hook";}];}];
        };
      };
      blocks = ((result.config.programs.claude-code.settings or {}).hooks or {}).UserPromptSubmit or [];
      cmds = handlerCommands blocks;
    in
      builtins.elem "consumer-hook" cmds
      && builtins.any (lib.hasInfix "claude-delegation-clamp") cmds
  );

  # ── memory-collision guard (ai.claude.memoryCollisionGuard) ───────
  # Default-OFF is the requirement here, and it is the exact inverse of the
  # delegation clamp's above. This hook DENIES a tool call, so shipping it on by
  # default would block writes for every consumer who never asked for it.
  module-claude-hm-memory-collision-guard-default-off = mkTest "claude-hm-memory-collision-guard-default-off" (
    let
      result = evalHm {ai.claude.enable = true;};
      settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
    in
      hasGuardHook (settingsHooks.PreToolUse or []) == false
  );

  # Opting in must produce a PreToolUse entry matching the write-shaped tools. The
  # matcher is asserted because it is half the filter: the script's path test is the
  # other half, and a matcher regression would spawn the hook on every tool call.
  module-claude-hm-memory-collision-guard-opt-in = mkTest "claude-hm-memory-collision-guard-opt-in" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          memoryCollisionGuard.enable = true;
        };
      };
      blocks = ((result.config.programs.claude-code.settings or {}).hooks or {}).PreToolUse or [];
      guardBlocks = builtins.filter (b: hasGuardHook [b]) blocks;
    in
      builtins.length guardBlocks
      == 1
      && (builtins.head guardBlocks).matcher == "Write|Edit"
  );

  # Devenv parity — same hook, same default, per the repo's config-parity rule.
  module-claude-devenv-memory-collision-guard-opt-in = mkTest "claude-devenv-memory-collision-guard-opt-in" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          memoryCollisionGuard.enable = true;
        };
      };
      settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
      offResult = evalDevenv {ai.claude.enable = true;};
      offJson = (offResult.config.files.".claude/settings.json" or {}).json or {};
    in
      hasGuardHook (settingsJson.hooks.PreToolUse or [])
      && hasGuardHook (offJson.hooks.PreToolUse or []) == false
  );

  # Compose-not-clobber, same reasoning as the clamp's: emitted as a DEFINITION of
  # ai.claude.hooks rather than as that option's `default`, so a consumer who
  # defines PreToolUse for their own reasons keeps both.
  module-claude-memory-collision-guard-composes-with-consumer-hook = mkTest "claude-memory-collision-guard-composes-with-consumer-hook" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          memoryCollisionGuard.enable = true;
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [{command = "consumer-hook";}];
            }
          ];
        };
      };
      blocks = ((result.config.programs.claude-code.settings or {}).hooks or {}).PreToolUse or [];
      cmds = handlerCommands blocks;
    in
      builtins.elem "consumer-hook" cmds
      && builtins.any (lib.hasInfix "claude-memory-collision-guard") cmds
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

  module-claude-hooks-command-resolves-package-pname = mkTest "claude-hooks-command-resolves-package-pname" (
    let
      pkg = pkgs.runCommand "demo-hook-no-main-program" {pname = "demo-hook";} ''
        mkdir -p "$out/bin"
        touch "$out/bin/demo-hook"
      '';
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

  # ── ai.shell — root default with per-runtime override ───────────
  #
  # The FIRST `ai.*` surface whose shared/per-runtime pair resolves by
  # override rather than by collision-as-failure, so the precedence
  # cases below are the contract, not incidental coverage. Three
  # runtimes consume it through three different mechanisms; two are
  # excluded outright. See dev/fragments/ai-module/shell-option.md.

  # Default null must touch nothing — the whole opt-in premise.
  module-ai-shell-default-null-is-inert = mkTest "ai-shell-default-null-is-inert" (
    let
      hm = evalHm {
        ai.claude.enable = true;
        ai.codex.enable = true;
      };
      claudeSettings = hm.config.programs.claude-code.settings or {};
      # Unwrapped codex keeps the bare upstream store path.
      codexPkg = builtins.head hm.config.home.packages;
    in
      !((claudeSettings.env or {}) ? CLAUDE_CODE_SHELL)
      && !(lib.hasSuffix "-wrapped" (builtins.baseNameOf codexPkg))
  );

  # Root → Claude's dedicated variable (NOT SHELL — Claude ignores that).
  module-ai-shell-root-reaches-claude = mkTest "ai-shell-root-reaches-claude" (
    let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.claude.enable = true;
      };
      settings = result.config.programs.claude-code.settings or {};
    in
      (settings.env.CLAUDE_CODE_SHELL or null) == (lib.getExe pkgs.bash)
  );

  # Per-runtime beats root. `bashNonInteractive` is a genuinely distinct
  # derivation from `bash` in this pinned nixpkgs (`bash` IS
  # `bashInteractive` here), which is what makes this assertion able to
  # fail at all — two names for one store path would pass vacuously.
  module-ai-shell-per-runtime-overrides-root = mkTest "ai-shell-per-runtime-overrides-root" (
    let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.claude = {
          enable = true;
          shell = pkgs.bashNonInteractive;
        };
      };
      settings = result.config.programs.claude-code.settings or {};
    in
      (settings.env.CLAUDE_CODE_SHELL or null)
      == (lib.getExe pkgs.bashNonInteractive)
      && lib.getExe pkgs.bashNonInteractive != lib.getExe pkgs.bash
  );

  # Kiro reads SHELL from its own process env; HM bakes exports into the
  # symlinkJoin wrapper, so the value must be visible in the launcher.
  module-ai-shell-kiro-hm-wrapper-carries-shell = let
    result = evalHm {
      ai.shell = pkgs.bash;
      ai.kiro.enable = true;
    };
  in
    mkWrapperGrepTest {
      name = "ai-shell-kiro-hm-wrapper-carries-shell";
      package = builtins.head result.config.home.packages;
      bin = "kiro-cli";
      needles = ["SHELL" (lib.getExe pkgs.bash)];
    };

  # Codex had NO wrapper before this option; one is built on demand.
  module-ai-shell-codex-hm-wrapper-carries-shell = let
    result = evalHm {
      ai.shell = pkgs.bash;
      ai.codex.enable = true;
    };
  in
    mkWrapperGrepTest {
      name = "ai-shell-codex-hm-wrapper-carries-shell";
      package = builtins.head result.config.home.packages;
      bin = "codex";
      needles = ["SHELL" (lib.getExe pkgs.bash)];
    };

  # Devenv parity: same root option, same resolved value, both backends.
  module-ai-shell-hm-devenv-parity = mkTest "ai-shell-hm-devenv-parity" (
    let
      hm = evalHm {
        ai.shell = pkgs.bash;
        ai.claude.enable = true;
      };
      devenv = evalDevenv {
        ai.shell = pkgs.bash;
        ai.claude.enable = true;
      };
      hmValue =
        (hm.config.programs.claude-code.settings or {}).env.CLAUDE_CODE_SHELL or null;
      devenvFile = devenv.config.files.".claude/settings.json" or null;
      devenvValue =
        if devenvFile == null
        then null
        else devenvFile.json.env.CLAUDE_CODE_SHELL or null;
    in
      hmValue != null && hmValue == devenvValue
  );

  # Explicit consumer value still wins over the option (mkDefault).
  module-ai-shell-explicit-settings-wins = mkTest "ai-shell-explicit-settings-wins" (
    let
      result = evalHm {
        ai.shell = pkgs.bash;
        ai.claude = {
          enable = true;
          settings.env.CLAUDE_CODE_SHELL = "/usr/bin/bash";
        };
      };
      settings = result.config.programs.claude-code.settings or {};
    in
      (settings.env.CLAUDE_CODE_SHELL or null) == "/usr/bin/bash"
  );

  # PRECEDENCE, and it must be the SAME on every runtime. Module-contributed
  # values (the typed `ai.shell`, the sandbox-safe SSH default) merge UNDER
  # the consumer's `environmentVariables`, so an explicit entry wins.
  #
  # Codex briefly did the opposite — it applied the typed option last, on the
  # reasoning that the typed surface is more specific. Defensible alone, wrong
  # in aggregate: the identical two-key config then resolved differently
  # depending on which runtime the consumer named. These two tests exist to
  # keep the two runtimes agreeing, so change them together or not at all.
  module-ai-shell-explicit-env-beats-typed-codex = let
    result = evalHm {
      ai.shell = pkgs.bash;
      ai.codex = {
        enable = true;
        environmentVariables.SHELL = "/explicit/zsh";
      };
    };
  in
    mkWrapperGrepTest {
      name = "ai-shell-explicit-env-beats-typed-codex";
      package = builtins.head result.config.home.packages;
      bin = "codex";
      needles = ["/explicit/zsh"];
      absentNeedles = [(lib.getExe pkgs.bash)];
    };

  module-ai-shell-explicit-env-beats-typed-kiro = let
    result = evalHm {
      ai.shell = pkgs.bash;
      ai.kiro = {
        enable = true;
        environmentVariables.SHELL = "/explicit/zsh";
      };
    };
  in
    mkWrapperGrepTest {
      name = "ai-shell-explicit-env-beats-typed-kiro";
      package = builtins.head result.config.home.packages;
      bin = "kiro-cli";
      needles = ["/explicit/zsh"];
      absentNeedles = [(lib.getExe pkgs.bash)];
    };

  # POSITIVE CONTROL for the two exclusion tests below. They assert an
  # eval FAILURE, and a test that only ever asserts failure passes just as
  # happily when the harness is broken for an unrelated reason — at which
  # point it proves nothing while still reporting green. This runs the
  # identical tryEval shape against a runtime that DOES support the option
  # and requires success, so the pair can only both hold if `tryEval` is
  # actually discriminating on the option's existence. Do not delete one
  # without the other.
  module-ai-shell-accepted-for-claude = mkTest "ai-shell-accepted-for-claude" (
    let
      probe =
        builtins.tryEval
        (evalHm {
          ai.claude = {
            enable = true;
            shell = pkgs.bash;
          };
        })
      .config.home.packages;
    in
      probe.success
  );

  # Copilot and Kimchi opt OUT: the option must NOT exist for them, so a
  # consumer setting one gets an eval error instead of a value that
  # evaluates cleanly and is then silently dropped.
  module-ai-shell-excluded-for-copilot = mkTest "ai-shell-excluded-for-copilot" (
    let
      probe =
        builtins.tryEval
        (evalHm {
          ai.copilot = {
            enable = true;
            shell = pkgs.bash;
          };
        })
      .config.home.packages;
    in
      !probe.success
  );

  module-ai-shell-excluded-for-kimchi = mkTest "ai-shell-excluded-for-kimchi" (
    let
      probe =
        builtins.tryEval
        (evalHm {
          ai.kimchi = {
            enable = true;
            shell = pkgs.bash;
          };
        })
      .config.home.packages;
    in
      !probe.success
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
  # Legacy Markdown directories are Claude + Copilot only. Codex is excluded
  # because its agents are semantic records rendered to standalone TOML; Kiro
  # is excluded because these are Markdown while Kiro's agents are JSON, and
  # its tool tags are a different vocabulary (separate `ai.kiro.agents` /
  # `ai.kiro.agentsDir` surfaces handle that).

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
      # The cross-harness SSH default is exercised separately; this assertion
      # guards only against baking the Kimchi credential into the environment.
      && removeAttrs result.config.env ["GIT_SSH_COMMAND"] == {}
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
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      bin=${wrapped}/bin/kimchi
      grep -q "KIMCHI_NO_UPDATE_CHECK" "$bin"
      grep -q "KIMCHI_EXTRA" "$bin"
      grep -q 'cat "/run/secrets/kimchi-test"' "$bin"
      # An empty credential file must abort the wrapper rather than let the
      # program start with the variable unset. Asserted on a REAL MCP
      # wrapper, not only glab's, because the guard lives in the shared
      # lib/credentials.nix and every server inherits it.
      grep -q 'KIMCHI_API_KEY resolved empty' "$bin"
      echo PASS > "$out"
    '';

  # The guard is the point of the change, so exercise it as SHELL rather
  # than as a grep: run a generated snippet against a genuinely empty file
  # and against a populated one. A grep proves the line was emitted; only
  # running it proves the line works.
  module-credential-empty-guard-aborts = let
    credLib = import ./../lib/credentials.nix {inherit lib;};
    # `mkSecretExport` bakes the path in at generation time and the test
    # needs two different files, so the path is a placeholder substituted
    # per-case below.
    runner = pkgs.writeShellScript "empty-guard-runner" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${credLib.mkSecretExport pkgs "TEST_TOKEN" {file = "@SECRET@";}}
      echo "REACHED-PROGRAM"
    '';
  in
    pkgs.runCommand "module-test-credential-empty-guard-aborts" {
      nativeBuildInputs = [pkgs.gnused];
    } ''
      # stdenv's buildCommand already runs with errexit, pipefail AND
      # inherit_errexit on (measured against the pinned nixpkgs), so this
      # line is not what makes a failing assertion below fail the build.
      # It adds the three stdenv deliberately leaves off — `-u`, `-E`, `-T`
      # — and brings the snippet in line with the repo-wide strict-mode
      # rule. Verified safe here: setting them inside a buildCommand does
      # not upset the phases stdenv runs afterwards.
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      empty=$(mktemp) && : > "$empty"
      full=$(mktemp) && printf 'a-real-token' > "$full"
      sed "s|@SECRET@|$full|"  ${runner} > full.sh
      sed "s|@SECRET@|$empty|" ${runner} > empty.sh

      # Positive control. Without it, a guard that rejected EVERYTHING would
      # still pass the negative case below and look correct.
      got=$(${pkgs.bash}/bin/bash full.sh 2>&1)
      [ "$got" = "REACHED-PROGRAM" ] || {
        echo "FAIL: populated secret was rejected (got: $got)" >&2
        exit 1
      }

      # A DIRECTORY must abort with the guard's own message. `-r` alone is
      # true for a readable directory, so without the `-d` branch this
      # sails past and dies on `cat: …: Is a directory`, losing the
      # variable name and the path the guard exists to report.
      mkdir -p secret-dir
      sed "s|@SECRET@|$PWD/secret-dir|" ${runner} > dir.sh
      if got=$(${pkgs.bash}/bin/bash dir.sh 2>&1); then
        echo "FAIL: a directory as the secret path did not abort (got: $got)" >&2
        exit 1
      fi
      case "$got" in
        *"is a directory, not a secret file"*) : ;;
        *)
          echo "FAIL: directory aborted, but not via the guard (got: $got)" >&2
          exit 1 ;;
      esac

      # The real case: an empty file must abort, non-zero, before the
      # program is reached.
      if got=$(${pkgs.bash}/bin/bash empty.sh 2>&1); then
        echo "FAIL: empty secret did not abort the wrapper (got: $got)" >&2
        exit 1
      fi
      case "$got" in
        *REACHED-PROGRAM*)
          echo "FAIL: reached the program despite the guard" >&2; exit 1 ;;
        *"TEST_TOKEN resolved empty"*) : ;;
        *)
          echo "FAIL: aborted, but not via the guard (got: $got)" >&2; exit 1 ;;
      esac

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

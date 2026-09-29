{
  lib,
  pkgs,
  moduleImports,
  testing,
}: let
  mcpLib = import ../mcp.nix {inherit lib;};
  aiBase = import ../ai {inherit lib;};
  aiTypes = import ../ai/types.nix {inherit lib;};
  # The runtime registry, shared with lib/ai/sharedOptions.nix and
  # checks/modules/options-doc.nix. Importing it rather than restating the five names
  # is what makes the tests below GROW when a sixth runtime lands: a hardcoded
  # list would keep passing while silently not covering the newcomer.
  harnessNames = import ../ai/runtimes.nix;
  tomlFormat = pkgs.formats.toml {};
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
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      # Home-manager provides these XDG paths in a real eval. Semble uses
      # cacheHome for its Codex sandbox grant, while glab uses stateHome for its
      # keyring synchronization marker.
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

  # Stub devenv's files option and the other options the factory config
  # callbacks set, so they evaluate without importing devenv.
  devenvStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      # Same reason as hmStubs above: the module-system branch is the real one.
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      # Real devenv exposes this at EVAL time — `devenv eval devenv.state`
      # returns an absolute path — which is what lets packages/glab derive
      # a project-local configDir with no runtime shell expansion.
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
      git.root = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/tmp/devenv-root";
      };
      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      processes = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
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
      treefmt.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };
  aiStubs = (pkgs.ai or {}) // testing.homeManagerAiPackages;
  # Prepend to HM activation text a runtime check executes; hm-run.sh says why.
  hmRunShim = builtins.readFile ./hm-run.sh;

  evalHmModulesWithSpecialArgs = extraSpecialArgs: modules:
    lib.evalModules {
      specialArgs =
        {
          lib = hmLib;
          pkgs = pkgs // {ai = aiStubs;};
          inherit (hmLib) hm;
        }
        // extraSpecialArgs;
      modules =
        [../ai/sharedOptions.nix]
        ++ moduleImports "homeManager"
        ++ [hmStubs]
        ++ modules;
    };
  evalHmWithSpecialArgs = extraSpecialArgs: config: evalHmModulesWithSpecialArgs extraSpecialArgs [{inherit config;}];
  evalHm = evalHmWithSpecialArgs {};
  # A whole module rather than a config attrset, for a configuration that
  # declares options of its own (a stand-in for an upstream module).
  evalHmModules = evalHmModulesWithSpecialArgs {};

  evalDevenvModulesWithSpecialArgs = extraSpecialArgs: modules:
    lib.evalModules {
      specialArgs =
        {
          codexGitCommonDirResolver = _: null;
          lib = hmLib;
          pkgs = pkgs // {ai = pkgs.ai or {};};
        }
        // extraSpecialArgs;
      modules =
        [../ai/sharedOptions.nix]
        ++ moduleImports "devenv"
        ++ [devenvStubs]
        ++ modules;
    };
  evalDevenvWithSpecialArgs = extraSpecialArgs: config: evalDevenvModulesWithSpecialArgs extraSpecialArgs [{inherit config;}];
  evalDevenv = evalDevenvWithSpecialArgs {};
  # A whole module rather than a config attrset, for a configuration that reads
  # `config` or declares assertions of its own (this repository's dev/ai.nix).
  evalDevenvModules = evalDevenvModulesWithSpecialArgs {};
  # The deterministic root tests assert paths only their injected resolver can
  # produce, so losing this specialArgs-only seam fails loudly instead of
  # silently measuring production builtins.getEnv behavior.
  evalDevenvWithGetEnv = codexGetEnv: evalDevenvWithSpecialArgs {inherit codexGetEnv;};
  mkTest = mkAssertion "module-test";
  mkAssertion = prefix: name: assertion:
    pkgs.runCommand "${prefix}-${name}" {} ''
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
  # (packages/copilot-cli/checks/copilot-wrapper-argv.nix, packages/kiro-cli/checks/kiro-wrapper-argv.nix), which
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
  # `lib.hasInfix` compiles its argument into a `builtins.match` regex, so a
  # needle containing `*` or `.` — which every glob does — silently matches
  # strings it should not (`"/*.json"` matches any `".json"`). `splitString`
  # escapes its separator, so this is a true literal search. Use it whenever
  # the needle is shell syntax rather than prose.
  hasLiteral = needle: hay: builtins.length (lib.splitString needle hay) > 1;
  # The `own` plan ONE writer applies, as recorded by `helpers.mkOwnBundle`:
  # `bash` plus the ordered targets, with each target's codec, path, ledger and
  # units. The plan FILE is a derivation, so reading it back would be
  # import-from-derivation; this is the same value, eval-visible, and the
  # writer is built from it rather than from a mirror of it. Read a render
  # command as `(ownPlan …).targets` → the target's `units.<name>.run`, and a
  # dir unit's mode as that unit's `mode`.
  #
  # It THROWS on an absent entry rather than defaulting to `{}`: a renamed or
  # dropped writer must fail a check, never satisfy one with an empty plan.
  ownPlan = runtime: entry: evaluated:
    (lib.attrByPath ["ai" runtime "_ownPlans" entry]
      (throw "module-test: config.ai.${runtime}._ownPlans.\"${entry}\" is missing")
      evaluated.config)
    .plan;
  # What one writer's plan will assert into one runtime-writable document:
  # `{ledger, value}`, found by the document PATH rather than by the writer's
  # entry name, because that is the identity a settings check cares about.
  #
  # `value` cannot come out of the plan itself — a document target's content is
  # `builtins.toJSON value`, and `builtins.fromJSON` refuses a string that
  # refers to a store path — so it is read from the same record's `declared`
  # map, which the `mkOwnBundle` caller fills from the value it serialized.
  ownedDocument = runtime: path: evaluated: let
    plans =
      lib.attrByPath ["ai" runtime "_ownPlans"]
      (throw "module-test: config.ai.${runtime}._ownPlans is missing")
      evaluated.config;
    hits = lib.concatMap (record:
      map (target: {
        inherit (target) ledger;
        value =
          record.declared.${path}
          or (throw "module-test: ai.${runtime} owns \"${path}\" through a plan that declared no value for it");
      })
      (lib.filter (target: target.codec != "dir" && target.path == path) record.plan.targets)) (lib.attrValues plans);
  in
    if lib.length hits == 1
    then lib.head hits
    else throw "module-test: expected exactly one ai.${runtime} document plan for \"${path}\", found ${toString (lib.length hits)}";
  # A Claude JSON document as delivered on either backend: the value its
  # `ai.claude.files` entry renders, `{}` when none is declared. Throws when an
  # entry is declared but the backend's symlink sink does not carry it, so a
  # value can never pass for a file nothing writes.
  claudeDocument = path: evaluated: let
    inherit (evaluated) config;
    sink =
      if config ? home
      then config.home.file
      else config.files;
    entry = config.ai.claude.files.${path} or null;
  in
    if entry == null
    then {}
    else if sink ? ${path}
    then entry.content.value
    else throw "module-test: ai.claude.files.\"${path}\" is declared but not delivered";
  claudeSettings = claudeDocument ".claude/settings.json";
  # Where Claude's MCP servers land: the project .mcp.json on devenv, the
  # personal plugin's .mcp.json on Home Manager.
  claudeMcpPath = backend:
    if backend == "hm"
    then ".claude/skills/home-manager/.mcp.json"
    else ".mcp.json";
  claudeMcpServers = backend: evaluated: (claudeDocument (claudeMcpPath backend) evaluated).mcpServers or {};
  # Every file devenv delivers, whichever writer lands it: the native `files`
  # sink entries for symlinks, plus each unit of an owned writer's directory
  # plan for a read-only copy, as `{text}` or `{source}` plus its `mode`. The
  # shared AGENTS.md owner (`ai.internal`) is a writer like any runtime. Read
  # it where a check asks what reaches the project tree rather than how: a
  # file that moves from a symlink to a copy stays where the check looks.
  # Takes the evaluated `config`.
  deliveredFiles = config: let
    copiesOf = target:
      lib.optionals (target.codec == "dir") (lib.mapAttrsToList (address: unit: {
          name =
            if target.path == "."
            then address
            else "${target.path}/${address}";
          value =
            lib.optionalAttrs (unit ? text) {inherit (unit) text;}
            // lib.optionalAttrs (unit ? store) {source = unit.store;}
            // lib.optionalAttrs (unit ? mode) {inherit (unit) mode;};
        })
        target.units);
    copies = lib.concatMap (plans:
      lib.concatMap (record: lib.concatMap copiesOf record.plan.targets)
      (builtins.attrValues plans))
    (map (runtime: lib.attrByPath ["ai" runtime "_ownPlans"] {} config) (harnessNames ++ ["internal"]));
  in
    builtins.listToAttrs copies // (config.files or config.home.file);
  # The `{text}` or `{source}` a Markdown file goes into its runtime's
  # generated tree as. What is delivered is a store path into that tree, and
  # reading it back would be import-from-derivation, so a check about a
  # Markdown file's content reads it here and a check about where the file
  # lands reads `deliveredFiles` / `home.file`. Found by the final entry: the
  # shared AGENTS.md owner (`ai.internal`) wins, because on devenv it is the
  # one that delivers a shared key; otherwise exactly one enabled runtime must
  # carry the path. A path with a byte limit is in a tree whatever its
  # format, as the router builds one tree per invocation. Takes the evaluated module (`evalHm …`,
  # `evalDevenv …`).
  markdownInput = evaluated: path: let
    inherit (evaluated) config;
    owners =
      lib.filter (runtime: (config.ai.${runtime}.enable or false) && (config.ai.${runtime}.files or {}) ? ${path})
      harnessNames;
    owner =
      if (config.ai.internal.files or {}) ? ${path}
      then "internal"
      else if lib.length owners == 1
      then lib.head owners
      else throw "module-test: expected exactly one ai.* entry for \"${path}\", found ${toString (lib.length owners)}";
    entry = config.ai.${owner}.files.${path};
  in
    if (entry.format == "markdown" || config.ai.${owner}._maxBytes ? ${path}) && entry.content.enable
    then aiTypes.textSourceFile entry.content
    else throw "module-test: \"${path}\" is not a live generated tree entry (format `${entry.format}`, no byte limit)";
  # Whether a delivered file record (`home.file.<p>`, `files.<p>`, a
  # `deliveredFiles` entry) is `path` inside its runtime's generated tree.
  fromTree = kind: path: file: lib.hasSuffix "-${kind}/${path}" (toString (file.source or ""));
  fromGeneratedTree = fromTree "generated";
  # The text a delivered file's tree was built from, once the record it lands
  # as (its `deliveredFiles` entry, on either backend) is checked to BE that
  # tree's file. Takes the evaluated module.
  deliveredMarkdown = evaluated: path: let
    file = (deliveredFiles evaluated.config).${path};
  in
    if fromGeneratedTree path file
    then (markdownInput evaluated path).text
    else throw "module-test: ${path} is not delivered from its generated tree";
  # The shell-entry lines of a devenv evaluation that run the AGENTS.md
  # window notice, matched by the notice's store path. Takes the evaluated
  # module.
  windowNoticeLines = evaluated: lib.filter (lib.hasInfix "/bin/ai-markdown-window-notice ") (lib.splitString "\n" evaluated.config.enterShell);
  # The parsed `<envelope>.<server>` entry of a rendered LSP file, or null.
  # Null unless `envelope` is the file's ONLY top-level key, so a bare
  # per-server map (which Copilot and Kiro both reject) never matches.
  # `fromJSON` refuses a string carrying store-path context, which a
  # `package`-resolved command adds.
  lspEntryOf = envelope: file: server: let
    content =
      if file ? text && file.text != null
      then file.text
      else builtins.readFile file.source;
    json = builtins.fromJSON (builtins.unsafeDiscardStringContext content);
  in
    if file != null && lib.attrNames json == [envelope]
    then json.${envelope}.${server} or null
    else null;
in {
  inherit aiBase aiStubs claudeMcpPath claudeMcpServers claudeSettings deliveredFiles deliveredMarkdown devenvStubs evalDevenv evalDevenvModules evalDevenvWithGetEnv evalDevenvWithSpecialArgs evalHm evalHmModules evalHmWithSpecialArgs fromGeneratedTree harnessNames hasLiteral hmLib hmRunShim hmStubs lspEntryOf markdownInput mcpConfigKeyOf mcpLib mkAssertion mkTest mkWrapperGrepTest ownedDocument ownPlan tomlFormat windowNoticeLines;
  inherit testing;
}

{
  # False evaluates the modules over `pkgs` exactly as given, with no `ai`
  # attribute injected, so a module default must come from
  # `ai.internal.roots` (this flake's build) or fail.
  injectAi ? true,
  inputs,
  lib,
  moduleImports,
  moduleInternals,
  pkgs,
  testing,
}: let
  mcpLib = import ../mcp.nix {inherit lib;};
  aiBase = import ../ai {inherit lib;};
  fileLib = import ../../packages/ai-module/lib/files/default.nix {inherit lib pkgs;};
  # The runtime registry, shared with lib/ai/sharedOptions.nix and
  # checks/modules/options-doc.nix. Importing it rather than restating the five names
  # is what makes the tests below GROW when a sixth runtime lands: a hardcoded
  # list would keep passing while silently not covering the newcomer.
  harnessNames = import ../ai/runtimes.nix;
  optionPaths = import ../ai/option-paths.nix {inherit lib pkgs;};
  setEnable = runtime: lib.setAttrByPath (optionPaths.enable runtime);
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
          entryBetween = _: _: text: {inherit text;};
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
        # Codex keys hook trust by the absolute path of the user's hooks.json.
        homeDirectory = lib.mkOption {
          type = lib.types.str;
          default = "/home/test";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
        };
        sessionVariables = lib.mkOption {
          type = lib.types.attrsOf (lib.types.oneOf [lib.types.str lib.types.path lib.types.int lib.types.float]);
          default = {};
        };
      };
      # Home Manager's real value type, so a check rejects what Home Manager
      # rejects (a four-level key, a null); an `attrsOf anything` stub hid
      # exactly that once. `enable` defaults to false, as in Home Manager.
      programs.git = {
        enable = lib.mkEnableOption "Git";
        settings = lib.mkOption {
          type = import ../git-tool-settings/ini-type.nix {inherit lib;};
          default = {};
        };
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
        # Home Manager's own default; ai-module's service step runs it.
        systemctlPath = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.systemd}/bin/systemctl";
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
  # callbacks set, without importing the full devenv module graph.
  # Compute upstream's linked targets and copy modes; retain the declared fields
  # so factory snapshots do not acquire upstream's function-valued formats.
  devenvFileTargets = files:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        "${inputs.devenv}/src/modules/files.nix"
        {
          _module.check = false;
          inherit files;
        }
      ];
    }).config.files;
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
        apply = files: let
          targets = devenvFileTargets files;
        in
          lib.mapAttrs (path: entry: entry // {inherit (targets.${path}) copyMode file;}) files;
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
      treefmt = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        config.settings.global.excludes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
        };
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
          pkgs =
            if injectAi
            then pkgs // {ai = aiStubs;}
            else pkgs;
          inherit (hmLib) hm;
        }
        // extraSpecialArgs;
      modules =
        [../ai/sharedOptions.nix]
        ++ moduleImports "homeManager"
        ++ [hmStubs]
        ++ [{ai.internal = moduleInternals;}]
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
          pkgs =
            if injectAi
            then pkgs // {ai = pkgs.ai or {};}
            else pkgs;
        }
        // extraSpecialArgs;
      modules =
        [../ai/sharedOptions.nix]
        ++ moduleImports "devenv"
        ++ [devenvStubs]
        ++ [{ai.internal = moduleInternals;}]
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
  # single argv token — are owned by
  # packages/kiro-cli/checks/kiro-wrapper-argv.nix, which executes the wrapper
  # against an argv-printing stub. A grep cannot prove any
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
  # The `ro`/`rw` entries of the normalized `ai.files` plan, the ones the
  # engine writes; `claimedBy` keeps those under a key the runtime's layer 1
  # claims (a recursive key claims its leaves).
  engineEntries = config:
    lib.filter (item: item.method != "symlink") (fileLib.normalize {
      backend =
        if config ? home
        then "hm"
        else "devenv";
      files = config.ai.files;
      namespace = "ai";
    });
  claimedBy = runtime: config: item:
    lib.any (key: item.path == key || lib.hasPrefix "${key}/" item.path)
    (builtins.attrNames (lib.filterAttrs (_path: owners: lib.elem runtime owners) config.ai.claims.path));
  # The engine's normalized `ro`/`rw` entries claimed by one runtime.
  # Keep the explicit phase argument so a stale writer name fails its check.
  ownPlan = runtime: entry: evaluated: let
    targets = lib.filter (claimedBy runtime evaluated.config) (engineEntries evaluated.config);
  in
    if entry != "files-apply"
    then throw "module-test: expected the files-apply engine phase, got ${entry}"
    else if targets == []
    then throw "module-test: ai.${runtime} claims no ro or rw entry of ai.files"
    else {inherit targets;};
  # A runtime's writable document, found by the final root-relative path.
  ownedDocument = runtime: path: evaluated: let
    entry = lib.findFirst (item: item.path == path && item.method == "rw" && claimedBy runtime evaluated.config item) null (engineEntries evaluated.config);
  in
    if entry != null
    then {inherit (entry.content) value;}
    else throw "module-test: ai.${runtime} claims no rw document at \"${path}\"";
  # A Claude JSON document as delivered on either backend: the value of its
  # layer-1 entry (`ai.claude.files`), `{}` when none is declared. Throws when
  # an entry is declared but the backend's symlink sink does not carry it, so a
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
  # Native symlinks plus normalized engine copies and writable documents.
  deliveredFiles = config: let
    engine = map (item: lib.nameValuePair item.path (item.content // {inherit (item) method;} // lib.optionalAttrs (item.mode != null) {inherit (item) mode;})) (engineEntries config);
  in
    builtins.listToAttrs engine // (config.files or config.home.file);
  # The actual generated-tree derivation that supplies a delivered file. The
  # source equality keeps this tied to the sink rather than merely selecting a
  # same-runtime tree with a copied build recipe.
  deliveredTree = evaluated: path: let
    inherit (evaluated) config;
    file = (deliveredFiles config).${path};
    trees = lib.filter (tree:
      tree
      != null
      && (file.source or null) == "${tree}/${path}")
    (map (runtime: config.ai.${runtime}._generatedTree or null) (harnessNames ++ ["internal"]));
  in
    if lib.length trees == 1
    then lib.head trees
    else throw "module-test: expected exactly one generated tree delivering \"${path}\", found ${toString (lib.length trees)}";
  # The `{text}` or `{source}` a live build-time file goes into its runtime's
  # generated tree as. What is delivered is a store path into that tree, and
  # reading it back would be import-from-derivation, so a check about the input
  # content reads it here and a check about where the file lands reads
  # `deliveredFiles` / `home.file`. Found by the final entry: the shared
  # AGENTS.md owner (`ai.internal`) wins; otherwise exactly one enabled runtime
  # must carry the path. Every live build-time entry is in the tree, whatever
  # its format; `run` content and `shared` document leaves are not. A path a
  # runtime's layer 1 claims is read from that runtime's staged entry
  # (`_generatedFiles`), the input of the same tree. Takes the evaluated module
  # (`evalHm …`, `evalDevenv …`).
  markdownInput = evaluated: path: let
    inherit (evaluated) config;
    claims = config.ai.claims.path.${path} or [];
    staged =
      config.ai.${lib.head claims}._generatedFiles.${path}
      or (throw "module-test: \"${path}\" is not a staged generated entry of ai.${lib.head claims}");
  in
    if claims == []
    then throw "module-test: \"${path}\" has no runtime claim"
    else if staged.enable && builtins.elem staged.content._choice ["source" "text"]
    then {${staged.content._choice} = staged.content.${staged.content._choice};}
    else throw "module-test: \"${path}\" is not a live staged text or source entry";
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
in {
  inherit aiBase aiStubs claudeMcpPath claudeMcpServers claudeSettings deliveredFiles deliveredMarkdown deliveredTree devenvStubs evalDevenv evalDevenvModules evalDevenvWithGetEnv evalDevenvWithSpecialArgs evalHm evalHmModules evalHmWithSpecialArgs fromGeneratedTree harnessNames hasLiteral hmLib hmRunShim hmStubs markdownInput mcpConfigKeyOf mcpLib mkAssertion mkTest mkWrapperGrepTest ownedDocument ownPlan setEnable tomlFormat;
  inherit testing;
}

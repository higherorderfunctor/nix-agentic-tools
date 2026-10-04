# nat-overlay-parity — this flake ships ONE build of each package, whoever asks.
#
# The exported overlay re-exports the builds of this flake's own nixpkgs rather
# than rebuilding on the consumer's `final`, and every module default reads the
# same builds, so a consumer on any nixpkgs hits the cache. Nothing else proves
# that: a regression (an overlay that builds on `final` again, a module site
# that reads raw `pkgs.ai`) still evaluates and still builds, just not from the
# cache. Every assertion compares drvPath strings; nothing is built.
#
#   A  the overlay over a foreign nixpkgs gives `ciPackages`' drv for every
#      claimed leaf, and the claim list is complete
#   B  license config is hash-neutral: `packages` equals `ciPackages` by name,
#      and only the unfree leaves are missing from it
#   C  the overlay never sets unfree for the consumer
#   D  positive controls: the foreign nixpkgs differs, and building on it
#      (buildOverlay) gives a different drv
#   E  every module package default, both backends, with and without the
#      overlay, over a base with NO `ai` attribute
#   F  the fallback (non-native triple) still builds on `final`
#   G  `gateKeys` matches the config keys nixpkgs' meta checks read
#   H  no module file reads raw `pkgs.ai`
#
# Linux only: F uses pkgsStatic, and the foreign nixpkgs imports are paid once
# where `nix flake check` runs in CI.
{
  buildOverlay,
  claimedPaths,
  gateKeys,
  harnessFor,
  inputs,
  lib,
  natSystemOf,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  drvOf = drv: builtins.unsafeDiscardStringContext drv.drvPath;
  outOf = drv: builtins.unsafeDiscardStringContext drv.outPath;
  sorted = lib.sort lib.lessThan;
  ciPackages = self.ciPackages.${system};
  publicPackages = self.packages.${system};
  overlay = self.overlays.default;

  # ── Foreign nixpkgs ────────────────────────────────────────────────
  # An input's own nixpkgs, never this flake's: no new flake input, and
  # llm-agents' is fetched whenever semble evaluates anyway. devenv's is the
  # fallback should llm-agents ever lock this flake's revision.
  foreignSource =
    lib.findFirst (source: source.narHash != inputs.nixpkgs.narHash)
    (throw "nat-overlay-parity: every candidate foreign nixpkgs is this flake's own revision; add another")
    [inputs.llm-agents.inputs.nixpkgs inputs.devenv.inputs.nixpkgs];
  foreignWith = config: import foreignSource {inherit config system;};
  foreign = foreignWith {allowUnfree = true;};
  foreignFree = foreignWith {};
  overlaid = foreign.extend overlay;

  # ── A: overlay re-export ───────────────────────────────────────────
  repoDocs = builtins.filter (lib.hasPrefix "repo-") (builtins.attrNames ciPackages);
  leafNames = sorted (lib.subtractLists repoDocs (builtins.attrNames ciPackages));
  claimNames = sorted (lib.unique (map lib.last claimedPaths));
  overlayMismatches =
    map (keyPath: "overlay ${lib.concatStringsSep "." keyPath} differs from ciPackages.${lib.last keyPath}")
    (builtins.filter (keyPath: drvOf (lib.getAttrFromPath keyPath overlaid) != drvOf ciPackages.${lib.last keyPath}) claimedPaths);

  # ── B: license config is hash-neutral ──────────────────────────────
  publicNames = builtins.attrNames publicPackages;
  unfreeNames = sorted (builtins.filter (name: ciPackages.${name}.meta.unfree or false) leafNames);
  licenseMismatches =
    map (name: "packages.${name} differs from ciPackages.${name}")
    (builtins.filter (name: drvOf publicPackages.${name} != drvOf ciPackages.${name}) publicNames);

  # ── E: module defaults ─────────────────────────────────────────────
  # One row per module site that defaults a package. `read` takes the
  # evaluated config; `path` is the leaf under `ai`, whose basename is its
  # `ciPackages` name. `match` is `same` (the value IS the package) or
  # `contains` (the value carries its out path: an installed list, a script).
  runtimes = {
    claude = "claude-code";
    codex = "chatgpt-codex";
    copilot = "copilot-cli";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  gitTools = ["git-absorb" "git-branchless" "git-revise"];
  rulePath = ".claude/rules/heading.md";
  rows = backend:
    lib.mapAttrsToList (runtime: leaf: {
      name = "${backend} ai.${runtime}.package";
      path = [leaf];
      read = config: config.ai.${runtime}.package;
    })
    runtimes
    ++ map (tool: {
      name = "${backend} git ${tool} installed";
      path = ["gitTools" tool];
      read = config:
        if backend == "hm"
        then config.home.packages
        else config.packages;
      match = "contains";
    })
    gitTools
    ++ [
      {
        name = "${backend} glab.package";
        path = ["devTools" "glab"];
        read = config: config.glab.package;
      }
      {
        name = "${backend} ai.programs.semble.package";
        path = ["semble"];
        read = config: config.ai.programs.semble.package;
      }
      {
        name = "${backend} ai.internal.packages rumdl";
        path = ["devTools" "rumdl"];
        read = config: config.ai.internal.packages.devTools.rumdl;
      }
    ]
    ++ lib.optionals (backend == "devenv") [
      {
        name = "devenv git:branchless-init";
        path = ["gitTools" "git-branchless"];
        read = config: config.tasks."git:branchless-init".exec;
        match = "contains";
      }
      {
        name = "devenv services.beads.package";
        path = ["devTools" "beads"];
        read = config: config.services.beads.package;
      }
    ]
    ++ lib.optionals (backend == "hm") [
      {
        name = "hm mcp-servers context7-mcp package";
        path = ["mcpServers" "context7-mcp"];
        read = config: config.services.mcp-servers.servers.context7-mcp.package;
      }
    ];
  enabled = backend:
    {
      ai.claude = {
        enable = true;
        files.".claude/settings.json".content.enable = false;
        rules.heading.text = "#   Heading";
      };
      git = lib.genAttrs ["absorb" "branchless" "revise"] (_: {enable = true;});
      glab.enable = true;
    }
    // lib.optionalAttrs (backend == "devenv") {
      git-hooks.enable = true;
      services.beads.enable = true;
    }
    // lib.optionalAttrs (backend == "hm") {
      services.mcp-servers.servers.context7-mcp.enable = true;
    };
  # The tableCells guard a runtime's generated tree runs. Its program is
  # built from the module's pkgs with this flake's tree as `ai`, so it is
  # compared with the program built from the same base and `expectedAi`.
  guardsTable = import ../../lib/markdown/guards.nix {inherit lib;};
  guardRow = harness: evaluated: base: expectedAi: let
    expected = builtins.unsafeDiscardStringContext (lib.getExe (guardsTable.table (base // {ai = expectedAi;}) true).tableCells.program);
  in
    lib.optional (!harness.hasLiteral expected (harness.deliveredTree evaluated rulePath).buildPhase)
    "guard tableCells in the claude tree is not built from this flake's rumdl";
  # A bridge service's launcher puts mcp-proxy on its PATH, and ExecStart is
  # only the launcher's path. So pin the source instead: the launcher must
  # equal the one built with `expectedAi` as the package tree, and must change
  # when that tree's mcp-proxy is swapped for a marker.
  bridgeRow = harness: evaluated: fixture: expectedAi: let
    execWith = packages:
      (harness.evalHmModules [
        {config = fixture;}
        {ai.internal.packagesFor = lib.mkForce (_: packages);}
      ])
      .config
      .systemd
      .user
      .services
      .mcp-context7-mcp
      .Service
      .ExecStart;
    expected = execWith expectedAi;
    marked = execWith (expectedAi // {mcpServers = expectedAi.mcpServers // {mcp-proxy = pkgs.emptyDirectory;};});
  in
    lib.optional (evaluated.config.systemd.user.services.mcp-context7-mcp.Service.ExecStart != expected)
    "mcp-servers bridge launcher is not built from this flake's mcp-proxy"
    ++ lib.optional (marked == expected)
    "mcp-servers bridge launcher does not read mcp-proxy from ai.internal.packages";
  moduleMismatches = {
    base,
    expectedAi,
    label,
  }: let
    harness = harnessFor {
      pkgs = base;
      injectAi = false;
    };
    evaluate = backend: let
      fixture = enabled backend;
      modules =
        lib.optional (backend == "devenv") {
          options.git-hooks.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        }
        ++ [{config = fixture;}];
    in
      if backend == "hm"
      then harness.evalHmModules modules
      else harness.evalDevenvModules modules;
    check = backend: let
      evaluated = evaluate backend;
    in
      map (row: "${label}: ${row.name}") (builtins.filter (row: let
        expected = lib.getAttrFromPath row.path expectedAi;
        value = row.read evaluated.config;
      in
        if (row.match or "same") == "same"
        then drvOf value != drvOf expected
        else if builtins.isList value
        then !(builtins.elem (drvOf expected) (map drvOf value))
        else !(harness.hasLiteral (outOf expected) value)) (rows backend))
      ++ map (message: "${label}: ${backend} ${message}") (guardRow harness evaluated base expectedAi
        ++ lib.optionals (backend == "hm") (bridgeRow harness evaluated (enabled backend) expectedAi));
  in
    check "hm" ++ check "devenv";
  # Run 1: no overlay. The base has no `ai`, so a site still reading raw
  # `pkgs.ai` throws instead of passing; every default must be ciPackages'.
  # Run 2: the overlay applied; every default must be the overlay attribute.
  ciAi = pkgs.ai;
  defaultMismatches =
    moduleMismatches {
      base = foreign;
      expectedAi = ciAi;
      label = "no overlay";
    }
    ++ moduleMismatches {
      base = overlaid;
      expectedAi = overlaid.ai;
      label = "overlay";
    };

  # ── F: fallback ────────────────────────────────────────────────────
  staticPkgs = pkgs.pkgsStatic;
  staticRumdl = builtins.tryEval (drvOf (staticPkgs.extend overlay).ai.devTools.rumdl);

  # ── G: gate keys follow nixpkgs ────────────────────────────────────
  # Every `config.<k>`, `config ? <k>` and `inherit (config) <k>` token in the
  # three files nixpkgs' meta checks live in. A bump that adds, drops or
  # renames a gate key changes this set and fails here, naming the key.
  ignoredKeys = [
    # Read there, deliberately not forwarded: diagnostics, and the `problems`
    # schema skews between nixpkgs revisions.
    "checkMeta"
    "checkMetaRecursively"
    "handleEvalIssue"
    "inHydra"
    "problems"
    # Scan false positives: prose and the `problems` submodule's own fields.
    "allow"
    "handler"
    "name"
    "nix"
    "package"
  ];
  metaCheckTokens = let
    capturesOf = regex: text: builtins.filter builtins.isList (builtins.split regex text);
    identifier = "([A-Za-z_][A-Za-z0-9_'-]*)";
    tokensOf = text:
      map (captures: builtins.elemAt captures 1) (capturesOf "config(\\.|[[:space:]]*\\?[[:space:]]*)${identifier}" text)
      ++ lib.concatMap (captures: builtins.filter (word: builtins.isString word && word != "") (builtins.split "[[:space:]]+" (lib.head captures)))
      (capturesOf "inherit[[:space:]]*\\(config\\)([^;]*);" text);
  in
    sorted (lib.unique (lib.concatMap (file: tokensOf (builtins.readFile "${inputs.nixpkgs}/pkgs/stdenv/generic/${file}.nix"))
        ["check-meta" "problems" "remediations"]));
  expectedTokens = sorted (gateKeys ++ ignoredKeys);

  # ── H: no raw module reads ─────────────────────────────────────────
  # Every module file, with `#` comments dropped. A new module that passes
  # the unmodified pkgs to a factory (`inherit pkgs;`) is NOT caught here,
  # only by adding its row to E.
  nixFilesUnder = dir:
    lib.filter (lib.hasSuffix ".nix") (map toString (lib.filesystem.listFilesRecursive dir));
  moduleFiles =
    lib.concatMap (owner: let
      dir = ../../packages + "/${owner}/modules";
    in
      lib.optionals (builtins.pathExists dir) (nixFilesUnder dir))
    (builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../packages)))
    ++ [(toString ../../lib/git-tool-settings/tool-module.nix)];
  withoutComments = text: lib.concatMapStringsSep "\n" (line: lib.head (lib.splitString "#" line)) (lib.splitString "\n" text);
  rawReads = builtins.filter (file: lib.hasInfix "pkgs.ai" (withoutComments (builtins.readFile file))) moduleFiles;
  relative = file: lib.removePrefix "${toString ../..}/" file;

  failures =
    lib.optional (claimedPaths == []) "A: no claimed paths; the overlay re-exports nothing"
    ++ lib.optional (claimNames != leafNames)
    "A: claim basenames ${toString claimNames} != ciPackages leaves ${toString leafNames}"
    ++ map (message: "A: ${message}") overlayMismatches
    ++ map (message: "B: ${message}") licenseMismatches
    ++ lib.optional (unfreeNames == []) "B: no unfree leaf; the unfree filter is untested"
    ++ lib.optional (sorted (lib.subtractLists publicNames (builtins.attrNames ciPackages)) != unfreeNames)
    "B: ciPackages minus packages is not exactly the unfree leaves ${toString unfreeNames}"
    ++ lib.optional (builtins.tryEval (drvOf (foreignFree.extend overlay).ai.claude-code)).success
    "C: the overlay evaluated an unfree package without the consumer's opt-in"
    ++ lib.optional (drvOf foreign.hello == drvOf pkgs.hello)
    "D: the foreign nixpkgs builds the same hello; it is not foreign"
    ++ lib.optional (drvOf (foreign.extend buildOverlay).ai.devTools.rumdl == drvOf publicPackages.rumdl)
    "D: buildOverlay on the foreign nixpkgs matches packages.rumdl; parity would pass vacuously"
    ++ map (message: "E: ${message}") defaultMismatches
    ++ lib.optional (natSystemOf pkgs != system) "F: natSystemOf rejects this flake's own native set"
    ++ lib.optional (natSystemOf staticPkgs != null) "F: natSystemOf accepts pkgsStatic"
    ++ lib.optional (!staticRumdl.success) "F: the pkgsStatic fallback does not evaluate rumdl"
    ++ lib.optional (staticRumdl.success && staticRumdl.value == drvOf publicPackages.rumdl)
    "F: the pkgsStatic fallback re-exported the native rumdl"
    ++ lib.optional (metaCheckTokens != expectedTokens)
    "G: nixpkgs' meta checks read ${toString (lib.subtractLists expectedTokens metaCheckTokens)} not in gateKeys/ignoredKeys, and no longer read ${toString (lib.subtractLists metaCheckTokens expectedTokens)}"
    ++ map (file: "H: ${relative file} reads raw pkgs.ai; read config.ai.internal.packages") rawReads;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    nat-overlay-parity =
      if failures != []
      then throw "nat-overlay-parity:\n  ${lib.concatStringsSep "\n  " failures}"
      else
        pkgs.runCommand "nat-overlay-parity" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          {
            echo "claims: ${toString (builtins.length claimedPaths)}"
            echo "packages compared: ${toString (builtins.length publicNames)}"
            echo "unfree leaves: ${toString (builtins.length unfreeNames)}"
            echo "module rows: ${toString (builtins.length (rows "hm") + builtins.length (rows "devenv") + 3)} per run, 2 runs"
            echo "gate keys: ${toString (builtins.length gateKeys)}"
            echo "module files scanned: ${toString (builtins.length moduleFiles)}"
          } > "$out"
        '';
  };
}

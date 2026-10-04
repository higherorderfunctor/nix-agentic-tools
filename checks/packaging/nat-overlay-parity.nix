# nat-overlay-parity — this flake ships ONE build of each package, whoever asks.
#
# The exported overlay re-exports the builds of this flake's own nixpkgs rather
# than rebuilding on the consumer's `final`, and every module default reads the
# same builds, so a consumer on any nixpkgs hits the cache. Nothing else proves
# that: a regression (an overlay that builds on `final` again, a module site
# that reads raw `pkgs.ai`) still evaluates and still builds, just not from the
# cache. Everything handed out passes through `checkedBy`, which must keep each
# drv while the receiver's own nixpkgs decides unfree. Every assertion compares
# drvPath or out path strings, or whether one evaluates; nothing is built.
#
#   A  the overlay over a foreign nixpkgs gives `ciPackages`' drv for every
#      claimed leaf, and the claim list is complete
#   B  `packages` and `legacyPackages` give `ciPackages`' drvs; only the unfree
#      leaves are missing from `packages`, and they refuse in `legacyPackages`;
#      every free leaf also evaluates on this flake's nixpkgs with NO config,
#      so none of them hands out an unfree dependency without the opt-in
#   C  the consumer's own meta check decides: without an opt-in every unfree
#      leaf refuses, every free leaf gives `ciPackages`' drv and reports
#      `meta.available`, and so do the module roots (`rootsFor`); `allowUnfree`
#      and `allowUnfreePredicate` each admit claude-code with that drv;
#      `.overrideAttrs` and `.overrideDerivation` are checked again
#   D  positive controls: the foreign nixpkgs differs, and building on it
#      (buildOverlay) gives a different drv
#   E  every module package default, both backends, with and without the
#      overlay, over a base with NO `ai` attribute
#   F  the fallback (non-native triple) still builds on `final`
#   G  no module file reads a root (`pkgs.ai`, `pkgs.docs`, ...) from raw pkgs
#
# Linux only: F uses pkgsStatic, and the foreign nixpkgs imports are paid once
# where `nix flake check` runs in CI.
#
# B's refusal rows assume a pure evaluation. Under `--impure` with
# NIXPKGS_ALLOW_UNFREE=1, or a ~/.config/nixpkgs/config.nix allowing unfree,
# `legacyPackages`' plain nixpkgs import admits the unfree leaves and B fails.
{
  buildOverlay,
  claimedPaths,
  harnessFor,
  inputs,
  lib,
  natSystemOf,
  pkgs,
  rootsFor,
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

  # ── B: the public outputs ──────────────────────────────────────────
  # Both are checked by a plain import of this flake's nixpkgs (default
  # config), so in a pure evaluation an unfree leaf refuses there.
  evaluation = value: builtins.tryEval (drvOf value);
  publicNames = builtins.attrNames publicPackages;
  legacyPackages = self.legacyPackages.${system};
  isUnfree = name: ciPackages.${name}.meta.unfree or false;
  unfreeNames = sorted (builtins.filter isUnfree leafNames);
  # This flake's own set with no config: a free leaf that interpolates an
  # unfree dependency refuses here. Everything handed out comes from the
  # `allowUnfree` natSets, and the probe judges only the leaf's own meta, so
  # this is the only place a free leaf's dependencies are judged.
  strict = import inputs.nixpkgs {
    inherit system;
    overlays = [buildOverlay];
  };
  publicMismatches =
    map (name: "packages.${name} differs from ciPackages.${name}")
    (builtins.filter (name: drvOf publicPackages.${name} != drvOf ciPackages.${name}) publicNames)
    ++ map (name: "legacyPackages.${name} differs from ciPackages.${name}")
    (builtins.filter (name: drvOf legacyPackages.${name} != drvOf ciPackages.${name}) (lib.subtractLists unfreeNames leafNames))
    ++ map (name: "legacyPackages.${name} is unfree and evaluated without an opt-in")
    (builtins.filter (name: (evaluation legacyPackages.${name}).success) unfreeNames)
    ++ map (keyPath: "${lib.concatStringsSep "." keyPath} is free but does not evaluate without allowUnfree; an unfree dependency would reach consumers unchecked")
    (builtins.filter (keyPath: !isUnfree (lib.last keyPath) && !(evaluation (lib.getAttrFromPath keyPath strict)).success) claimedPaths);

  # ── C: the consumer's own meta check ───────────────────────────────
  # The overlay over the foreign nixpkgs with no opt-in: each claimed leaf is
  # judged by that nixpkgs' check. Refusing only the unfree leaves, while
  # the free ones keep ciPackages' drv, shows the probe is what refuses.
  overlaidWith = config: (foreignWith config).extend overlay;
  freeOverlaid = foreignFree.extend overlay;
  freeMismatches = lib.concatMap (keyPath: let
    name = lib.last keyPath;
    result = evaluation (lib.getAttrFromPath keyPath freeOverlaid);
    path = lib.concatStringsSep "." keyPath;
  in
    if isUnfree name
    then lib.optional result.success "${path} is unfree and evaluated without an opt-in"
    else
      lib.optional (!(result.success && result.value == drvOf ciPackages.${name})) "${path} is free and does not give ciPackages' drv without an opt-in"
      ++ lib.optional (!(lib.getAttrFromPath keyPath freeOverlaid).meta.available) "${path} is free and reports meta.available = false without an opt-in")
  claimedPaths;
  claudeDrv = drvOf ciPackages.claude-code;
  givesClaude = set: let
    result = evaluation set.ai.claude-code;
  in
    result.success && result.value == claudeDrv;
  # A predicate that names one package: the consumer's predicate judges each
  # leaf by the probe's name (lib.getName), not all-or-nothing.
  namedOverlaid = overlaidWith {allowUnfreePredicate = package: lib.getName package == "claude-code";};
  rebuilt = set: set.ai.claude-code.overrideAttrs (_: {});
  rebuiltDerivation = set: set.ai.claude-code.overrideDerivation (_: {});
  # Module defaults without the overlay: `rootsFor` over the foreign nixpkgs.
  freeRoots = rootsFor foreignFree;
  consumerMismatches =
    lib.optional (!lib.elem "claude-code" unfreeNames) "claude-code is not an unfree leaf; the refusal rows below test nothing"
    ++ lib.optional (!(evaluation ciPackages.claude-code).success) "ciPackages.claude-code does not evaluate; a refusal would not be the probe's"
    ++ lib.optional (!givesClaude overlaid) "with allowUnfree, ai.claude-code is not ciPackages' drv"
    ++ lib.optional (!givesClaude (overlaidWith {allowUnfreePredicate = _: true;})) "with allowUnfreePredicate, ai.claude-code is not ciPackages' drv"
    ++ lib.optional (!givesClaude namedOverlaid) "a predicate naming claude-code does not admit it"
    ++ lib.optional (evaluation namedOverlaid.ai.copilot-cli).success "a predicate naming claude-code admits copilot-cli"
    ++ lib.optional (evaluation (rebuilt freeOverlaid)).success "ai.claude-code.overrideAttrs evaluated without an opt-in"
    ++ lib.optional ((evaluation (rebuilt overlaid)).value != claudeDrv) "with allowUnfree, an identity overrideAttrs is not ciPackages' drv"
    ++ lib.optional (evaluation (rebuiltDerivation freeOverlaid)).success "ai.claude-code.overrideDerivation evaluated without an opt-in"
    ++ lib.optional ((evaluation (rebuiltDerivation overlaid)).value != claudeDrv) "with allowUnfree, an identity overrideDerivation is not ciPackages' drv"
    ++ lib.optional freeOverlaid.ai.claude-code.meta.available "ai.claude-code reports meta.available = true without an opt-in"
    ++ lib.optional (!overlaid.ai.claude-code.meta.available) "with allowUnfree, ai.claude-code reports meta.available = false"
    ++ lib.optional (evaluation freeRoots.ai.claude-code).success "rootsFor: ai.claude-code evaluated without an opt-in"
    ++ lib.optional ((evaluation freeRoots.ai.devTools.rumdl).value != drvOf ciPackages.rumdl) "rootsFor: ai.devTools.rumdl is not ciPackages' drv without an opt-in"
    ++ freeMismatches;

  # ── E: module defaults ─────────────────────────────────────────────
  # One row per module site that defaults a package. `read` takes the
  # evaluated config; `path` is the leaf under `ai`, whose basename is its
  # `ciPackages` name. `match` is `same` (the value IS the package) or
  # `contains` (the value carries its out path: an installed list, a script).
  # A site that reads a root other than `ai`, or builds a new derivation from
  # one, is a source row instead (sourceRows below).
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
  # Merged recursively: the devenv part adds to `ai`, it must not replace it.
  enabled = backend:
    lib.foldl' lib.recursiveUpdate {
      ai.claude = {
        enable = true;
        files.".claude/settings.json".content.enable = false;
        rules.heading.text = "#   Heading";
      };
      ai.programs = lib.genAttrs ["delegate-routing" "kimchi-docs" "stacked-workflows"] (_: {enable = true;});
      git = lib.genAttrs ["absorb" "branchless" "revise"] (_: {enable = true;});
      glab.enable = true;
    } [
      (lib.optionalAttrs (backend == "devenv") {
        # The shared AGENTS.md writer runs the guards on this table.
        ai.codex = {
          enable = true;
          context.text = "| a | b |\n| - | - |\n| 1 | 2 |\n";
        };
        git-hooks.enable = true;
        services.beads.enable = true;
      })
      (lib.optionalAttrs (backend == "hm") {
        services.mcp-servers.servers.context7-mcp.enable = true;
      })
    ];
  # The tableCells guard a generated tree runs. Its program is built from the
  # module's pkgs with this flake's tree as `ai`, so it is compared with the
  # program built from the same base and `expectedRoots.ai`. One row per
  # writer: a runtime's own tree (the claude rule) and, on devenv, the shared
  # AGENTS.md writer.
  guardsTable = import ../../lib/markdown/guards.nix {inherit lib;};
  guardPaths = backend:
    {claude = rulePath;}
    // lib.optionalAttrs (backend == "devenv") {"shared AGENTS.md" = "AGENTS.md";};
  guardRows = harness: backend: evaluated: base: expectedRoots: let
    expected = builtins.unsafeDiscardStringContext (lib.getExe (guardsTable.table (base // {inherit (expectedRoots) ai;}) true).tableCells.program);
  in
    lib.concatLists (lib.mapAttrsToList (writer: path:
      lib.optional (!harness.hasLiteral expected (harness.deliveredTree evaluated path).buildPhase)
      "guard tableCells in the ${writer} tree is not built from this flake's rumdl")
    (guardPaths backend));
  # Sites whose value is not a root's leaf but is built from a root: a
  # launcher with mcp-proxy on its PATH, a skill rendered from a content
  # package, a skill linking a docs snapshot. Each is pinned by its source:
  # the value must equal the one evaluated with `expectedRoots` forced as
  # `ai.internal.roots`, and must change when `mark` swaps the root it reads
  # for a marker.
  marker = pkgs.emptyDirectory;
  withPassthru = drv: extra: drv // {passthru = drv.passthru // extra;};
  sourceRows = backend:
    [
      {
        name = "stacked-workflows skill";
        read = config: config.ai.claude.skills.stack-fix;
        mark = roots:
          roots
          // {
            stacked-workflows-content = withPassthru roots.stacked-workflows-content {
              skills = lib.mapAttrs (_: _: "${marker}") roots.stacked-workflows-content.passthru.skills;
            };
          };
      }
      {
        name = "delegate-routing skill";
        read = config: config.ai.claude.skills.delegate-routing;
        mark = roots: roots // {delegate-routing-content = withPassthru roots.delegate-routing-content {mkSkill = _: marker;};};
      }
      {
        name = "kimchi-docs skill";
        read = config: config.ai.claude.skills.kimchi-docs;
        mark = roots: roots // {docs = roots.docs // {kimchi-docs = marker;};};
      }
    ]
    ++ lib.optional (backend == "hm") {
      name = "mcp-servers bridge launcher";
      read = config: config.systemd.user.services.mcp-context7-mcp.Service.ExecStart;
      mark = roots: roots // {ai = roots.ai // {mcpServers = roots.ai.mcpServers // {mcp-proxy = marker;};};};
    };
  textOf = value: builtins.unsafeDiscardStringContext (toString value);
  moduleMismatches = {
    base,
    expectedRoots,
    label,
  }: let
    harness = harnessFor {
      pkgs = base;
      injectAi = false;
    };
    evaluate = backend: extraModules: let
      fixture = enabled backend;
      modules =
        lib.optional (backend == "devenv") {
          options.git-hooks.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        }
        ++ [{config = fixture;}]
        ++ extraModules;
    in
      if backend == "hm"
      then harness.evalHmModules modules
      else harness.evalDevenvModules modules;
    check = backend: let
      evaluated = evaluate backend [];
      readWith = roots: (evaluate backend [{ai.internal.rootsFor = lib.mkForce (_: roots);}]).config;
      sourceMismatches = row: let
        expected = textOf (row.read (readWith expectedRoots));
      in
        lib.optional (textOf (row.read evaluated.config) != expected)
        "${row.name} is not built from this flake's roots"
        ++ lib.optional (textOf (row.read (readWith (row.mark expectedRoots))) == expected)
        "${row.name} does not read its root from ai.internal.roots";
    in
      map (row: "${label}: ${row.name}") (builtins.filter (row: let
        expected = lib.getAttrFromPath row.path expectedRoots.ai;
        value = row.read evaluated.config;
      in
        if (row.match or "same") == "same"
        then drvOf value != drvOf expected
        else if builtins.isList value
        then !(builtins.elem (drvOf expected) (map drvOf value))
        else !(harness.hasLiteral (outOf expected) value)) (rows backend))
      ++ map (message: "${label}: ${backend} ${message}") (guardRows harness backend evaluated base expectedRoots
        ++ lib.concatMap sourceMismatches (sourceRows backend));
  in
    check "hm" ++ check "devenv";
  # Run 1: no overlay. The base has none of this flake's roots, so a site
  # still reading one from raw `pkgs` throws instead of passing; every default
  # must be ciPackages'. Run 2: the overlay applied; every default must be the
  # overlay attribute.
  rootNames = lib.unique (map builtins.head claimedPaths);
  rootsOf = set: lib.genAttrs rootNames (root: set.${root});
  defaultMismatches =
    moduleMismatches {
      base = foreign;
      expectedRoots = rootsOf pkgs;
      label = "no overlay";
    }
    ++ moduleMismatches {
      base = overlaid;
      expectedRoots = rootsOf overlaid;
      label = "overlay";
    };

  # ── F: fallback ────────────────────────────────────────────────────
  staticPkgs = pkgs.pkgsStatic;
  staticRumdl = builtins.tryEval (drvOf (staticPkgs.extend overlay).ai.devTools.rumdl);

  # ── G: no raw module reads ─────────────────────────────────────────
  # Every module file, with `#` comments dropped, searched for `pkgs.<root>`
  # for each root this flake claims. A new module that passes the unmodified
  # pkgs to a factory (`inherit pkgs;`) is NOT caught here, only by adding its
  # row to E. lib/ai/** is not scanned: its public factories take the caller's
  # pkgs by design, and a module path through them is an E row.
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
  rawRead = "(.*[^A-Za-z0-9_'-])?pkgs\\.(${lib.concatMapStringsSep "|" lib.escapeRegex rootNames})([^A-Za-z0-9_'-].*)?";
  rawReads = builtins.filter (file: lib.any (line: builtins.match rawRead line != null) (lib.splitString "\n" (withoutComments (builtins.readFile file)))) moduleFiles;
  relative = file: lib.removePrefix "${toString ../..}/" file;

  failures =
    lib.optional (claimedPaths == []) "A: no claimed paths; the overlay re-exports nothing"
    ++ lib.optional (claimNames != leafNames)
    "A: claim basenames ${toString claimNames} != ciPackages leaves ${toString leafNames}"
    ++ map (message: "A: ${message}") overlayMismatches
    ++ map (message: "B: ${message}") publicMismatches
    ++ lib.optional (unfreeNames == []) "B: no unfree leaf; the unfree filter is untested"
    ++ lib.optional (sorted (lib.subtractLists publicNames (builtins.attrNames ciPackages)) != unfreeNames)
    "B: ciPackages minus packages is not exactly the unfree leaves ${toString unfreeNames}"
    ++ map (message: "C: ${message}") consumerMismatches
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
    ++ map (file: "G: ${relative file} reads a root from raw pkgs; read config.ai.internal.roots") rawReads;
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
            echo "module rows: ${toString (lib.foldl' (n: backend: n + builtins.length (rows backend) + builtins.length (sourceRows backend) + builtins.length (builtins.attrNames (guardPaths backend))) 0 ["hm" "devenv"])} per run, 2 runs"
            echo "module files scanned: ${toString (builtins.length moduleFiles)}"
          } > "$out"
        '';
  };
}

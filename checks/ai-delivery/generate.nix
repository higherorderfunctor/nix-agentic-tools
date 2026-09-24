# Observe the delivery layer independently of the committed matrix. The output
# contains no module evaluation, package paths, content, or inferred probes.
{
  harness,
  lib,
  pkgs,
}: let
  facts = import ../../config/ai-delivery-facts.nix {inherit lib;};
  schema = import ../../config/ai-delivery-schema.nix {inherit lib;};
  specimen = import ./specimen.nix {inherit lib;};
  deliveryMethod = import ../../lib/ai/deliveryMethod.nix {inherit lib;};
  formats = import ../../lib/ai/formats.nix {inherit lib pkgs;};
  deliver = import ../../lib/ai/deliver.nix {inherit lib pkgs;};
  prefix = mode:
    if mode == "hm"
    then "$HOME/"
    else "$DEVENV_ROOT/";
  template = lib.replaceStrings ["/probe" "/scoped" "/SKILL.md"] ["/<name>" "/<name>" "/<leaf>"];
  writerPath = mode: name:
    (
      if mode == "hm"
      then ["home" "activation"]
      else ["tasks"]
    )
    ++ [name];
  viewFor = mode: runtime: strategy: let
    evaluated = (
      if mode == "hm"
      then harness.evalHm
      else harness.evalDevenv
    ) (specimen.config mode runtime strategy);
    inherit (evaluated) config options;
    cfg = config.ai.${runtime};
    # The existing shared owner holds these typed entries before step 16.
    # It is still the delivery layer, not a guessed backend file sink.
    shared =
      if mode == "devenv" && builtins.elem runtime ["codex" "kimchi" "kiro"]
      then config.ai.internal.files
      else {};
    files = lib.filterAttrs (_: entry: entry != null) (cfg.files // shared);
    router = deliver {
      inherit cfg config options runtime;
      backend = mode;
    };
    names = writerName: writer:
      [
        {
          phase = "write";
          name = router.nameFor "${writerName}.entry" writer.entry;
        }
      ]
      ++ lib.optional (mode == "hm" && writer.pruneEntry != null) {
        phase = "prune";
        name = router.nameFor "${writerName}.pruneEntry" writer.pruneEntry;
      };
    observe = path: entry: let
      method = deliveryMethod.resolve {
        inherit entry path;
        inherit (cfg) methodFor;
        backend = mode;
      };
      upstream = method == "upstream" && builtins.head entry.sink != "files";
      primitive =
        if upstream
        then "upstream"
        else
          {
            copy-ro = "ownPathManaged";
            shared = "ownLeaves";
            symlink = "ownPathDeclarative";
            upstream = "ownPathDeclarative";
          }.${
            method
          };
      leaf =
        if mode == "devenv" && entry.recursive
        then
          assert lib.assertMsg (builtins.hasAttr "${path}/SKILL.md" (formats.walk path entry.content.source))
          "ai-delivery: the recursive skill specimen has no SKILL.md"; "${path}/SKILL.md"
        else path;
      destinations =
        if builtins.elem primitive schema.imperativePrimitives
        then map (named: named // {writerAttr = writerPath mode named.name;}) (names entry.entry cfg.activation.${entry.entry})
        else [
          {
            phase = "write";
            writerAttr =
              if method == "upstream"
              then
                (
                  if upstream
                  then entry.sink
                  else lib.take 2 entry.sink
                )
              else
                (
                  if mode == "hm"
                  then ["home" "file"]
                  else ["files"]
                )
                ++ [leaf];
          }
        ];
    in
      lib.concatMap (surface:
        map (destination:
          {
            inherit primitive surface;
            ecosystem = runtime;
            inherit mode;
            target = prefix mode + template leaf;
            inherit (destination) writerAttr;
            pruneTrigger =
              if upstream
              then "upstream"
              else facts.pruneTrigger mode primitive;
            # Ordering chooses a representative, not a writer name. The body gate
            # still observes every distinct imperative strategy and HM phase.
            order =
              (
                if path == ".claude.json"
                then 20
                else if lib.hasSuffix "/harness/settings.json" path
                then 2
                else if surface == "hooks" && path != ".claude/settings.json"
                then 2
                else if surface == "rules" && !(builtins.elem path ["AGENTS.md" ".codex/AGENTS.md"])
                then 2
                else 0
              )
              + (
                if destination.phase == "prune"
                then 10
                else 0
              )
              + (
                if runtime == "kiro" && surface == "mcpServers" && strategy == "merge"
                then 5
                else 0
              );
          }
          // lib.optionalAttrs (runtime == "kiro" && surface == "mcpServers") {
            condition = facts.mcpConditions.${strategy};
          })
        destinations) (specimen.surfacesFor runtime path);
  in {
    inherit cfg config files names;
    records = lib.concatLists (lib.mapAttrsToList observe files);
  };
  views = lib.genAttrs schema.modes (mode:
    lib.genAttrs schema.ecosystems (runtime:
      lib.genAttrs (
        if runtime == "kiro"
        then specimen.modes
        else ["overwrite"]
      ) (viewFor mode runtime)));
  recordViews = lib.concatMap (mode: lib.concatMap (runtime: builtins.attrValues views.${mode}.${runtime}) schema.ecosystems) schema.modes;
  liveRecords = lib.concatMap (view: view.records) recordViews;
  retirementsFor = mode: runtime: let
    runtimeViews = builtins.attrValues views.${mode}.${runtime};
    view = views.${mode}.${runtime}.overwrite;
    claimed = lib.concatMap (v: map (entry: entry.ledger) (builtins.attrValues v.files)) runtimeViews;
    ledgerRows = writerName: writer: ledger: declaration: let
      primitive =
        if declaration.codec == "dir"
        then "ownPathManaged"
        else "ownLeaves";
      row = named: {
        inherit mode primitive;
        ecosystem = runtime;
        # A retired ledger's former surface is consumer knowledge.
        surface = assert lib.assertMsg (runtime == "kiro" && lib.hasSuffix "/steering" declaration.path)
        "ai-delivery: an unclaimed ledger needs a surface association"; "context";
        target = prefix mode + declaration.path + "/<legacy-owned-file>";
        writerAttr = writerPath mode named.name;
        pruneTrigger = facts.pruneTrigger mode primitive;
        order =
          if named.phase == "prune"
          then 30
          else 31;
      };
    in
      lib.optionals (!(builtins.elem ledger claimed)) (map row (view.names writerName writer));
    writerRows = name: writer: lib.concatLists (lib.mapAttrsToList (ledgerRows name writer) writer.ledgers);
  in
    lib.concatLists (lib.mapAttrsToList writerRows view.cfg.activation);
  retirements = lib.concatMap (mode: lib.concatMap (retirementsFor mode) schema.ecosystems) schema.modes;
  sorted = lib.sort (a: b:
    if a.order != b.order
    then a.order < b.order
    else builtins.toJSON a < builtins.toJSON b) (liveRecords ++ retirements);
  # Several specimen names can describe one templated declarative destination.
  # Imperative phases keep their actual names so no removal writer disappears.
  signature = row:
    builtins.toJSON ([(facts.key row) row.target row.primitive (row.condition or null)]
      ++ lib.optionals (row.primitive != "ownPathDeclarative") row.writerAttr);
  unique = lib.foldl' (acc: row:
    if lib.any (previous: signature previous == signature row) acc
    then acc
    else acc ++ [row]) []
  sorted;
  physical = lib.filter (row: row.primitive != "upstream") unique;
  groups = lib.groupBy facts.key physical;
  isDelegated = cell: facts.hand ? ${cell} && facts.hand.${cell}.primitive == "upstream";
  clean = row: builtins.removeAttrs row ["order"];
  child = row: builtins.removeAttrs (clean row) ["ecosystem" "mode" "surface"];
  data = {
    rows = lib.mapAttrsToList (_: group:
      clean (builtins.head group)
      // lib.optionalAttrs (builtins.length group > 1) {
        additionalWriters = map child (builtins.tail group);
      }) (lib.filterAttrs (cell: _: !(isDelegated cell)) groups);
    supplements = lib.mapAttrs (_: map child) (lib.filterAttrs (cell: _: isDelegated cell) groups);
  };
  # Claude's existing native devenv integration is outside the router's hosted
  # roots. Observe the hand-authored upstream destination, never fabricate an
  # entry for it. Package wrappers have no file surface and stay hand-authored.
  external = views.devenv.claude.overwrite.config.claude.code.mcpServers;
  liveKeys = lib.unique (map facts.key liveRecords ++ lib.optional (external != {}) "mcpServers/claude/devenv");
  absentKeys = lib.subtractLists liveKeys schema.expectedKeys;
  delegations =
    lib.filter (row: row.primitive == "upstream") unique
    ++ lib.optional (external != {}) {
      ecosystem = "claude";
      mode = "devenv";
      surface = "mcpServers";
      writerAttr = ["claude" "code" "mcpServers"];
    };
  assertionErrors = lib.concatMap (view: map (a: a.message) (lib.filter (a: !a.assertion) view.config.assertions)) recordViews;
  raw = pkgs.writeText "ai-delivery-generated-raw.nix" (
    "# Generated by checks/ai-delivery/generate.nix; do not edit.\n"
    + lib.generators.toPretty {} data
    + "\n"
  );
  generated = pkgs.runCommandLocal "ai-delivery-generated.nix" {nativeBuildInputs = [pkgs.alejandra];} ''
    cp ${raw} "$out"
    alejandra --quiet "$out"
  '';
in {
  inherit absentKeys assertionErrors data delegations generated;
}

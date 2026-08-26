# Generate `lib.mkOption` declarations for Claude's settings.json from the
# drift-checked sidecar (`overlays/claude-code-extracted.json` → `.settings`).
#
# The sidecar is produced by driving the packaged binary's OWN JSON-Schema
# emitter and its OWN `@internal` filter, so this file never hand-curates a key
# list. It consumes exactly the fixed sidecar contract:
#
#   settings = {
#     publicKeys   = [ <sorted top-level keys the binary's filter KEEPS> ];
#     internalKeys = [ <sorted top-level keys the binary's filter DROPS> ];
#     paths = {
#       "<dotted.path>" = {
#         type = "boolean"|"string"|"number"|"integer"|"array"
#              |"object"|"enum"|"anyOf"|"const";
#         enum = [ ... ];   # optional
#       };
#     };
#   };
#
# Path grammar: nested keys use dots, user-keyed maps use `.*`, array elements
# use `[]`. Container nodes may be IMPLICIT — `modelPricing.overrides.*` has no
# entry of its own, only `modelPricing.overrides.*.input` — so the tree walk
# synthesizes them.
#
# Consumed by packages/claude-code/lib/nativeSettingsOptions.nix, which merges
# `.options` with the hand-authored exceptions and hands the result to
# mkClaude.nix's `nativeSettings`, already declared as
#   lib.types.submodule { freeformType = (pkgs.formats.json {}).type; options = …; }
# so generated options slot straight into that existing structure. Nothing else
# should call `generate` — a second call site is a second exception table.
#
# ── The three invariants this file exists to hold ───────────────────────────
#
# 1. NEVER generate for an `internalKeys` entry. We honour the binary's own
#    filter rather than second-guessing it.
#
# 2. NO option may materialize a key the user never set. Every generated option
#    is `nullOr T` with `default = null`, and mkClaude lowers with
#    `aiCommon.filterNulls`, which drops both `null` and `{}` RECURSIVELY. An
#    unset nested submodule therefore evaluates to an all-null attrset, collapses
#    to `{}`, and is dropped before it can reach settings.json.
#
# 3. Arrays are NEVER given a typed element submodule — see `walkType`'s "array"
#    branch. `filterNulls` recurses into attrsets but NOT into lists, so a
#    `listOf (submodule { … })` element materializes `"serverCommand": null`
#    inside settings.json for every declared-but-unset element field, and
#    nothing downstream strips it. Array elements stay freeform.
#
# Hand-authored declarations always win (`externalPaths`), and every skip,
# override and unmappable type is REPORTED rather than silently dropped.
{lib}: let
  inherit (lib) types;

  # ── report plumbing ───────────────────────────────────────────────────────
  emptyReport = {
    # Path is declared by hand elsewhere in the submodule; the hand one wins
    # and the generator emitted nothing. Delete the hand one to reclaim it.
    collisions = [];
    # Path matched the override table; the override's declaration was emitted.
    overridden = [];
    # Path exists in the sidecar but has no sound Nix type; left to the
    # freeform passthrough (still settable, just untyped).
    unmapped = [];
    # `[]` subtrees deliberately left freeform (invariant 3).
    arrayElements = [];
    # A node carrying BOTH `.*` and named children; `attrsOf` cannot express
    # that, so it degraded to `attrsOf <freeform>`.
    mixedWildcard = [];
  };

  mergeReports = rs:
    lib.mapAttrs (name: _: lib.concatMap (r: r.${name} or []) rs) emptyReport;

  reportWith = fields: emptyReport // fields;

  sortStrs = lib.sort (a: b: a < b);

  # ── path parsing ──────────────────────────────────────────────────────────
  # One raw dotted segment can expand to TWO tree steps: `options[]` is the key
  # `options` followed by an element level.
  #
  # The `[]` suffix is peeled RECURSIVELY, and the remainder is re-parsed rather
  # than assumed to be a key. `hooks.*[]` is the motivating case: an array
  # hanging off a user-keyed map spells its element level onto the `*` segment,
  # so a parser that stripped `[]` and took the rest verbatim produced a named
  # child literally called `*`, sitting alongside the real wildcard node. Both
  # `hooks` and `sandbox.ignoreViolations` then looked like nodes carrying a
  # wildcard AND named children, which `attrsOf` cannot express — so each
  # degraded to `attrsOf freeformType` and was reported in `mixedWildcard`,
  # losing the element typing for no reason. Peeling first keeps `*[]` meaning
  # what the emitter spells: wildcard step, then element step.
  parseSegment = s:
    if s == "[]"
    then [{kind = "elem";}]
    else if lib.hasSuffix "[]" s
    then parseSegment (lib.removeSuffix "[]" s) ++ [{kind = "elem";}]
    else if s == "*"
    then [{kind = "wild";}]
    else [
      {
        kind = "key";
        name = s;
      }
    ];

  segmentsOf = path: lib.concatMap parseSegment (lib.splitString "." path);

  # ── tree construction ─────────────────────────────────────────────────────
  emptyNode = {
    type = null;
    enum = null;
    children = {};
    wild = null;
    elem = null;
  };

  orEmpty = n:
    if n == null
    then emptyNode
    else n;

  insertPath = node: segs: leaf:
    if segs == []
    then
      node
      // {
        type = leaf.type or null;
        enum = leaf.enum or null;
      }
    else let
      s = builtins.head segs;
      rest = builtins.tail segs;
    in
      if s.kind == "wild"
      then node // {wild = insertPath (orEmpty node.wild) rest leaf;}
      else if s.kind == "elem"
      then node // {elem = insertPath (orEmpty node.elem) rest leaf;}
      else
        node
        // {
          children =
            node.children
            // {
              ${s.name} = insertPath (orEmpty (node.children.${s.name} or null)) rest leaf;
            };
        };

  joinPath = prefix: name:
    if prefix == ""
    then name
    else "${prefix}.${name}";
in rec {
  # ── seed override table ───────────────────────────────────────────────────
  # HAND-AUTHORED OVERRIDES, keyed by dotted path. Adding a future exception is
  # one row here.
  #
  # A value is EITHER a finished option declaration (an attrset, normally from
  # `lib.mkOption`) OR a function `ctx -> option`, where
  #   ctx = { path; type; enum; generatedType; freeformType; }
  # `generatedType` is the type the generator WOULD have produced, so an
  # override can widen the machine-derived type instead of restating it — a
  # restated type silently stops tracking the binary the day upstream changes
  # it, which is the whole failure this extractor exists to end.
  #
  # An override only applies to a path that EXISTS in the sidecar. One that does
  # not is surfaced as `report.staleOverrides` rather than silently emitted, so
  # an upstream rename cannot leave a dead exception sitting here unnoticed.
  #
  # A plain attrset, not a builder: no row needs build-time data any more. A
  # future one that does (a model list, a version) turns this into a function
  # again, and there is exactly one call site to follow —
  # nativeSettingsOptions.nix.
  #
  # Two rows that used to live here are gone on purpose — do not restore either:
  #
  #   * `model` is hand-declared in nativeSettingsOptions.nix and named in
  #     `externalPaths`, so a row here would be INERT (`report.shadowedOverrides`
  #     exists to say so). One definition, not two.
  #   * `permissions.defaultMode` used to widen the emitted enum with "manual".
  #     The census now does that widening itself — it walks every `z.preprocess`
  #     transform sitting in front of an enum and confirms the alias against the
  #     real validator — so the sidecar's `enum` already means "what a user may
  #     legally write". A row here would restate a fact the extractor derives,
  #     and would go stale the day upstream adds or drops an alias.
  overrideTable = {
    # Open on purpose: the binary accepts arbitrary `custom:<name>` themes
    # alongside its built-ins, so neither the schema's enum nor an anyOf
    # branch set is a closed world here.
    theme = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Claude UI theme. Left open rather than enumerated: the binary accepts
        arbitrary `custom:<name>` theme ids in addition to its built-ins.
      '';
    };
  };

  # ── the generator ─────────────────────────────────────────────────────────
  #
  #   generate {
  #     settings       # the sidecar's `settings` object
  #     freeformType   # (pkgs.formats.json {}).type
  #     overrides ? {} # path -> option | (ctx -> option)
  #     externalPaths ? []  # paths hand-declared elsewhere; generator stands down
  #   }
  #   => { options = <attrsOf option declarations>; report = { … }; }
  #
  # Returns a RECORD, not a bare options attrset, because invariant 5 (a
  # collision with a hand-authored option must be REPORTABLE) cannot be carried
  # by the options attrset itself without polluting it with a fake option.
  # Callers use `.options`; a check consumes `.report`.
  generate = {
    settings,
    freeformType,
    overrides ? {},
    externalPaths ? [],
  }: let
    publicKeys = settings.publicKeys or [];
    internalKeys = settings.internalKeys or [];
    allPaths = settings.paths or {};

    firstSegment = path: builtins.head (lib.splitString "." (builtins.head (lib.splitString "[" path)));

    # Invariant 1: public keys only, and belt-and-braces against anything that
    # also shows up in internalKeys.
    isPublic = path: let
      top = firstSegment path;
    in
      lib.elem top publicKeys && !(lib.elem top internalKeys);

    # An anyOf BRANCH discriminator (`foo|0.bar`) is not part of the sidecar's
    # documented path grammar. Skip the path rather than invent a shape for it.
    isBranchPath = path: lib.hasInfix "|" path;

    keptPaths = lib.filterAttrs (p: _: isPublic p && !(isBranchPath p)) allPaths;
    droppedInternal = sortStrs (lib.filter (p: !(isPublic p)) (lib.attrNames allPaths));
    droppedBranch = sortStrs (lib.filter (p: isPublic p && isBranchPath p) (lib.attrNames allPaths));

    tree =
      lib.foldl'
      (acc: path: insertPath acc (segmentsOf path) keptPaths.${path})
      emptyNode
      (lib.attrNames keptPaths);

    describe = path: "Generated from the packaged claude-code settings schema (settings.json `${path}`).";

    # node -> { type = <nix type> | null; report = …; }
    walkType = path: node: let
      enumVals = node.enum or null;
      t = node.type or null;

      unmappable = reason:
        reportWith {unmapped = ["${path} (${reason})"];};

      objectish =
        # Named children AND a `.*` wildcard cannot both live under one
        # `attrsOf`. Degrade to freeform values and say so.
        if node.wild != null && node.children != {}
        then {
          type = types.attrsOf freeformType;
          report = reportWith {mixedWildcard = [path];};
        }
        else if node.wild != null
        then let
          w = walkType "${path}.*" node.wild;
        in {
          type = types.attrsOf (
            if w.type == null
            then freeformType
            else w.type
          );
          inherit (w) report;
        }
        else if node.children != {}
        then let
          c = walkChildren path node.children;
        in {
          type = types.submodule {
            inherit freeformType;
            inherit (c) options;
          };
          inherit (c) report;
        }
        else {
          type = types.attrsOf freeformType;
          report = emptyReport;
        };
    in
      # An explicit value set always wins over the declared scalar type: the
      # emitter spells a closed set as `type: "enum"`, but also attaches `enum`
      # to plain-typed and `const` nodes.
      # `enum` on an object node is the permitted KEY vocabulary of a record
      # (only `hooks` today), NOT a value set — typing it as `types.enum` makes
      # every `hooks.<Event>` definition fail to evaluate. Scalars only.
      if enumVals != null && enumVals != [] && t != "object" && t != "array"
      then {
        type = types.enum enumVals;
        report = emptyReport;
      }
      else if t == "boolean"
      then {
        type = types.bool;
        report = emptyReport;
      }
      else if t == "string"
      then {
        type = types.str;
        report = emptyReport;
      }
      else if t == "integer"
      then {
        type = types.int;
        report = emptyReport;
      }
      else if t == "number"
      then {
        type = types.number;
        report = emptyReport;
      }
      else if t == "array"
      then {
        # Invariant 3. Elements stay freeform; `filterNulls` cannot reach
        # inside a list to strip a submodule's null defaults.
        type = types.listOf freeformType;
        report = emptyReport;
      }
      else if t == "object" || (t == null && (node.children != {} || node.wild != null))
      then objectish
      else if t == "enum"
      then {
        type = null;
        report = unmappable "enum with no value set";
      }
      else if t == null
      then {
        type = null;
        report = unmappable "no type in sidecar";
      }
      else {
        # anyOf / const-without-enum / anything the emitter grows later. A
        # WRONG type rejects legal values; no type just falls through to the
        # freeform passthrough, which still accepts the key.
        type = null;
        report = unmappable t;
      };

    # path -> node -> { option = <declaration> | null; report = …; }
    walkOption = path: node: let
      elemNote =
        if node.elem != null
        then ["${path}[]"]
        else [];
    in
      # Hand-authored wins, and the whole subtree belongs to it.
      if lib.elem path externalPaths
      then {
        option = null;
        report = reportWith {
          collisions = [path];
          arrayElements = elemNote;
        };
      }
      else let
        t = walkType path node;
        withElem = mergeReports [t.report (reportWith {arrayElements = elemNote;})];
      in
        if overrides ? ${path}
        then let
          ov = overrides.${path};
          ctx = {
            inherit path freeformType;
            type = node.type or null;
            enum = node.enum or null;
            generatedType = t.type;
          };
        in {
          option =
            if lib.isFunction ov
            then ov ctx
            else ov;
          report = mergeReports [withElem (reportWith {overridden = [path];})];
        }
        else if t.type == null
        then {
          option = null;
          report = withElem;
        }
        else {
          option = lib.mkOption {
            type = types.nullOr t.type;
            # Invariant 2. Never a non-null default: a generated default that
            # leaks into settings.json changes behavior for every user.
            default = null;
            description = describe path;
          };
          report = withElem;
        };

    walkChildren = prefix: children: let
      entries =
        lib.mapAttrsToList (
          name: child: let
            r = walkOption (joinPath prefix name) child;
          in {
            inherit name;
            inherit (r) option report;
          }
        )
        children;
    in {
      options = lib.listToAttrs (
        map (e: lib.nameValuePair e.name e.option)
        (lib.filter (e: e.option != null) entries)
      );
      report = mergeReports (map (e: e.report) entries);
    };

    root = walkChildren "" tree.children;

    # A path that IS in the sidecar, at any depth.
    knownPath = p: allPaths ? ${p};
  in {
    inherit (root) options;

    report =
      lib.mapAttrs (_: sortStrs) root.report
      // {
        # Public top-level keys the sidecar never described — the tree walk had
        # nothing to build from.
        missingPaths = sortStrs (lib.filter (k: !(knownPath k)) publicKeys);
        # Exception-table rot: an override or hand-declaration aimed at a path
        # the binary no longer emits.
        staleOverrides = sortStrs (lib.filter (p: !(knownPath p)) (lib.attrNames overrides));
        staleExternalPaths = sortStrs (lib.filter (p: !(knownPath p)) externalPaths);
        # An override row that a hand-declaration shadows: `externalPaths` wins
        # (invariant 5), so the row is INERT. Either delete the hand
        # declaration and let the override own the path, or delete the row.
        shadowedOverrides =
          sortStrs (lib.filter (p: overrides ? ${p}) externalPaths);
        # Honouring the binary's own @internal filter (invariant 1), plus
        # anyOf-branch paths outside the documented grammar.
        internalSkipped = sortStrs internalKeys;
        internalPathsSkipped = droppedInternal;
        branchPathsSkipped = droppedBranch;
      };
  };
}

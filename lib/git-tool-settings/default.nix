# Typed options for the git config keys a git tool reads, generated from its
# drift-checked sidecar (`packages/<owner>/extracted.json`) as its rows file
# (`packages/<owner>/extract/annotations.json`) fills it, through ./rules.nix.
# One generator serves git-branchless, git-absorb and git-revise; each
# owner's lib/default.nix calls it with its sidecar, rows and hand tables.
#
# The sidecar is read as an ordinary committed file. Never pass a package's
# `passthru.extracted` derivation here: that is import-from-derivation and
# poisons evaluation for every consumer. Freshness is the update pipeline's
# and the `<tool>-extracted` drift check's problem.
#
# The option tree mirrors the git key path: `absorb.maxStack` is the option
# `absorb.maxStack`, so lowering needs no renaming table. Every scalar is
# `nullOr T` with `default = null`, and a null leaf writes nothing: git (and
# the tool) then fall through to a lower configuration scope, key by key. The
# `<name>` families are `attrsOf str` with `default = {}`. Only `settings`
# (the tool's own section) becomes options; `foreign` keys are git's own and
# stay raw git configuration.
#
# A key upstream adds becomes an option on the next evaluation after the
# sidecar is regenerated; the rows regeneration accepts it with a `{}` row,
# and the drift check fails until a person writes any prose it needs. A key upstream removes makes a
# consumer that still sets it fail with an unknown-option error, because
# every level of the tree is closed. A sidecar FIELD this file does not know
# fails evaluation (`schema` below): an extractor that learns something new
# must teach the generator too, or the fact would be dropped silently.
#
# Arguments:
#   lib, extracted     the nixpkgs lib and the parsed sidecar
#   rows               the parsed rows file. Its failures are the drift
#                      check's to report; options come from the entries.
#   tool               the program's name, used in descriptions
#   exclusions         key → reason it has no option
#   refinements        key → { type; refine; } narrowing what the sidecar's
#                      type admits, for a runtime rule the type alone does
#                      not carry. `refine {node; familyType;}` returns the
#                      value type (the generator adds nullOr) or, for a
#                      `<name>` family, the whole attrsOf type.
# Every hand-table row must name a key the sidecar still has, with the type
# it was written for — `report.stale*` lists any that do not.
#
# Returns:
#   options   nested option declarations, rooted at the tool's section
#   leaves    one { key; path; family; } per option leaf, for lowering
#   revsetFunctions   the sidecar's list, [] when it has none
#   report    { collisions; excluded; staleExclusions; staleRefinements; untyped; }
{
  lib,
  extracted,
  tool,
  exclusions ? {},
  refinements ? {},
  rows,
}: let
  inherit (lib) types;

  # The sidecar with each surface's facts replaced by its reconciled entries.
  merged = extracted // lib.mapAttrs (_: result: result.entries) (import ./rules.nix {inherit extracted lib rows;}).results;

  # ── The merged schema: every field an extractor or a row may write ────
  schema = let
    common = ["default" "defaultExpr" "fallback" "overriddenBy" "reads" "specialValues" "type" "values" "writes"];
  in {
    top = ["deadKeys" "foreign" "revsetFunctions" "settings" "source"];
    required = ["deadKeys" "foreign" "settings" "source"];
    setting = common ++ ["cli" "defaultDescription" "description" "documented" "invalid" "minimum" "note" "status"];
    foreign = common;
    value = ["description" "value"];
    cli = ["alsoSetBy" "doc" "flag"];
    deadKey = ["const" "file" "reason"];
    source = ["version"];
    invalid = ["default" "fallback"];
  };

  unknown = where: allowed: attrs:
    map (field: "${where}: unknown field `${field}`") (lib.subtractLists allowed (builtins.attrNames attrs));

  entryErrors = kind: key: node:
    unknown "${kind}.${key}" schema.${kind} node
    ++ lib.concatMap (v: unknown "${kind}.${key}.values" schema.value v) (node.values or [])
    ++ unknown "${kind}.${key}.cli" schema.cli (node.cli or {})
    ++ lib.optional (node ? minimum && !(builtins.isInt node.minimum)) "${kind}.${key}.minimum is not an integer"
    ++ lib.optional (node ? invalid && !(lib.elem node.invalid schema.invalid)) "${kind}.${key}.invalid is not one of ${toString schema.invalid}";

  # The top level first: the surfaces are reconciled only once they exist.
  topErrors =
    unknown "sidecar" schema.top extracted
    ++ map (field: "sidecar: missing `${field}`") (lib.subtractLists (builtins.attrNames extracted) schema.required);
  schemaErrors =
    if topErrors != []
    then topErrors
    else
      unknown "source" schema.source extracted.source
      ++ lib.concatLists (lib.mapAttrsToList (entryErrors "setting") merged.settings)
      ++ lib.concatLists (lib.mapAttrsToList (entryErrors "foreign") extracted.foreign)
      ++ lib.concatLists (lib.mapAttrsToList (key: unknown "deadKeys.${key}" schema.deadKey) merged.deadKeys);

  sidecar =
    if schemaErrors == []
    then merged
    else throw "lib/git-tool-settings: the ${tool} sidecar does not match the schema:\n  ${lib.concatStringsSep "\n  " schemaErrors}";

  # The tool reads `<name>` from the last segment of the key, and git folds a
  # dotted name's head into a case-sensitive subsection. Only plain names
  # render the same way on every backend, so dotted ones are rejected here;
  # raw git configuration can still set them.
  familyName = "[A-Za-z][A-Za-z0-9-]*";
  familyType = {
    valueType,
    nameCheck ? (_: true),
    nameRule ? "",
  }:
    types.addCheck (types.attrsOf valueType)
    (attrs: lib.all (name: builtins.match familyName name != null && nameCheck name) (builtins.attrNames attrs))
    // {
      description = "attribute set of ${valueType.description}, each name matching `^${familyName}$`${nameRule}";
    };

  # git config integers are 32-bit; a measured `minimum` raises the floor.
  intType = node:
    if node ? minimum
    then types.ints.between node.minimum 2147483647
    else types.ints.s32;

  scalarType = node: let
    t = node.type or null;
  in
    if t == "enum" && (node.values or []) != []
    then types.enum (map (v: v.value) node.values)
    else if t == "int"
    then intType node
    else
      {
        inherit (types) bool;
        path = types.str;
        string = types.str;
      }
      .${
        toString t
      }
      or null;

  # Keys with no option at all: the hand table, and keys the tool only
  # writes (a key nothing reads is not a setting).
  excludedReason = key: node: let
    derived =
      if node.reads == {}
      then "${tool} writes it and never reads it"
      else null;
  in
    exclusions.${key} or derived;

  isFamily = lib.hasSuffix ".<name>";
  pathOf = key: lib.splitString "." (lib.removeSuffix ".<name>" key);

  # key → node → { type; untyped; }
  typeOf = key: node: let
    base = scalarType node;
    refinement = refinements.${key} or null;
  in
    if refinement != null && refinement.type == (node.type or null)
    then {
      type = let
        refined = refinement.refine {inherit familyType node;};
      in
        if isFamily key
        then refined
        else types.nullOr refined;
      untyped = false;
    }
    else if base == null
    then {
      # A type the extractor grows later. The option still exists, but the
      # key is reported, so the generator checks fail until someone maps it.
      type = types.unspecified;
      untyped = true;
    }
    else if isFamily key
    then {
      type = familyType {valueType = base;};
      untyped = false;
    }
    else {
      type = types.nullOr base;
      untyped = false;
    };

  code = value: "`${builtins.toJSON value}`";
  flags = list: lib.concatMapStringsSep ", " (flag: "`${flag}`") list;

  # The upstream default: prose the annotations give, else the fallback
  # chain a read consults, else the literal default.
  defaultText = key: node: let
    terminal =
      if node ? default
      then code node.default
      else if node ? defaultExpr
      then "whatever `${node.defaultExpr}` computes"
      else "unset";
  in
    if node ? defaultDescription
    then ["${tool}'s default: ${node.defaultDescription}"]
    else if node ? fallback
    then ["When unset, ${tool} uses the value of ${lib.concatMapStringsSep ", then " (k: "`${k}`") node.fallback}; when that is unset too, ${terminal}."]
    else if node ? default
    then ["${tool}'s default is ${code node.default}."]
    else lib.optional (!isFamily key) "${tool} leaves it unset by default.";

  describe = key: node:
    lib.concatStringsSep " " (
      [(node.description or "${tool} `${key}`.")]
      ++ lib.optional (node.status or null == "legacy") "Deprecated upstream."
      ++ lib.optional (node.documented or true == false) "Undocumented upstream: this description comes from reading the source."
      ++ lib.optional (node.type or null == "enum")
      (lib.concatMapStringsSep "; " (v: "`${v.value}`: ${v.description or "no description upstream"}") node.values + ".")
      ++ defaultText key node
      ++ lib.optional (node ? specialValues) "Values ${tool} treats specially: ${lib.concatMapStringsSep ", " code node.specialValues}."
      ++ lib.optional (node ? cli)
      "The command-line flag `${node.cli.flag}`${lib.optionalString (node.cli.alsoSetBy or [] != []) " (also set by ${flags node.cli.alsoSetBy})"} (\"${node.cli.doc}\") is ORed with this setting: it can only turn it on for one run, so once the setting is true no flag turns it off."
      ++ lib.optional (node ? overriddenBy) "The command-line flags ${flags node.overriddenBy} override it for one run."
      ++ lib.optional (node.invalid or null == "default") "${tool} replaces a value it cannot parse with the default, silently."
      ++ lib.optional (node.invalid or null == "fallback") "${tool} treats a value it cannot parse as unset, silently, so the fallback applies."
      ++ lib.optional (node ? note) node.note
    );

  kept = lib.filterAttrs (key: node: excludedReason key node == null) sidecar.settings;
  typed = lib.mapAttrs typeOf kept;

  leaves = lib.mapAttrsToList (key: _: {
    inherit key;
    family = isFamily key;
    path = pathOf key;
  }) (lib.filterAttrs (key: _: !typed.${key}.untyped) kept);

  # Two keys where one's path is a prefix of the other's cannot both be
  # options: one would be a leaf and a branch at once.
  collisions = let
    paths = map (key: {
      inherit key;
      path = pathOf key;
    }) (builtins.attrNames kept);
    isPrefix = a: b: lib.length a < lib.length b && lib.take (lib.length a) b == a;
  in
    lib.sort (a: b: a < b) (lib.unique (lib.concatMap (a:
      lib.concatMap (b: lib.optional (isPrefix a.path b.path) "${a.key} / ${b.key}") paths)
    paths));

  option = key: node:
    lib.mkOption ({
        inherit (typed.${key}) type;
        description = describe key node;
      }
      // (
        if isFamily key
        then {default = {};}
        else {default = null;}
      ));

  options =
    if collisions != []
    then throw "lib/git-tool-settings: ${tool} keys whose paths nest cannot both be options: ${lib.concatStringsSep ", " collisions}"
    else lib.foldl' lib.recursiveUpdate {} (lib.mapAttrsToList (key: node: lib.setAttrByPath (pathOf key) (option key node)) kept);

  stale = table: check:
    lib.sort (a: b: a < b) (lib.filter (key: !(sidecar.settings ? ${key}) || !(check key sidecar.settings.${key})) (builtins.attrNames table));
in {
  inherit leaves options;
  revsetFunctions = sidecar.revsetFunctions or [];

  report = {
    inherit collisions;
    excluded = lib.mapAttrs excludedReason (lib.filterAttrs (key: node: excludedReason key node != null) sidecar.settings);
    staleExclusions = stale exclusions (_: _: true);
    staleRefinements = stale refinements (key: node: refinements.${key}.type == (node.type or null));
    untyped = lib.sort (a: b: a < b) (builtins.attrNames (lib.filterAttrs (_: t: t.untyped) typed));
  };
}

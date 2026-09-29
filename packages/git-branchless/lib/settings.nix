# Typed options for every `branchless.*` git config key git-branchless reads,
# generated from the drift-checked sidecar `packages/git-branchless/extracted.json`.
#
# The sidecar is read as an ordinary committed file. Never read the package's
# `passthru.extracted` derivation here: that is import-from-derivation and
# poisons evaluation for every consumer. Freshness is the update pipeline's
# and the `git-branchless-extracted` drift check's problem.
#
# The option tree mirrors the git key path: `branchless.smartlog.reverse` is
# the option `branchless.smartlog.reverse`, so lowering needs no renaming
# table. Every scalar is `nullOr T` with `default = null`, and a null leaf
# writes nothing: git (and git-branchless's libgit2) then fall through to a
# lower configuration scope, key by key. The `<name>` families are
# `attrsOf str` with `default = {}`.
#
# A key upstream adds becomes an option on the next evaluation after the
# sidecar is regenerated, with no hand step. A key upstream removes makes a
# consumer that still sets it fail with an unknown-option error, because
# every level of the tree is closed.
#
# Two hand tables are the only exceptions, and each row must name a key the
# sidecar still has, with the type it was written for — `report.stale*`
# lists any that do not, and checks/settings-options.nix fails on it:
#
#   exclusions   key → reason it has no option
#   refinements  key → { type; refine } narrowing what the sidecar's type
#                admits, for a runtime rule the type alone does not carry.
#                `refine` returns the value type (the generator adds nullOr)
#                or, for a `<name>` family, the whole attrsOf type.
#
# Returns:
#   options   nested option declarations, rooted at `branchless`
#   leaves    one { key; path; family; } per option leaf, for lowering
#   report    { collisions; excluded; staleExclusions; staleRefinements; untyped; }
{
  lib,
  extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
}: let
  inherit (lib) types;

  # git-branchless reads `<name>` from the last segment of the key, and git
  # folds a dotted name's head into a case-sensitive subsection. Only plain
  # names render the same way on every backend, so dotted ones are rejected
  # here; raw git configuration can still set them.
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

  exclusions = {
    "branchless.mainBranch" = "the legacy name of `branchless.core.mainBranch`, which git-branchless reads first. `git branchless init` writes that key into every repository it initializes, so this one never takes effect there; set `branchless.core.mainBranch` instead";
  };

  refinements = {
    # A negative value is a runtime error, and git-branchless reads an i32.
    "branchless.test.jobs" = {
      type = "int";
      refine = _: types.ints.between 0 2147483647;
    };
    # The builtin table is consulted before any alias, so an alias named
    # after a builtin is silently dead. The extractor fails if that lookup
    # order changes.
    "branchless.revsets.alias.<name>" = {
      type = "string";
      refine = _:
        familyType {
          valueType = types.str;
          nameCheck = name: !(lib.elem (lib.toLower name) extracted.revsetFunctions);
          nameRule = ", and none named after a builtin revset function";
        };
    };
  };

  scalarTypes = {
    inherit (types) bool;
    int = types.ints.s32;
    path = types.str;
    string = types.str;
  };

  # Keys with no option at all: the hand table, and keys git-branchless only
  # writes (a key nothing reads is not a setting).
  excludedReason = key: node: let
    derived =
      if node.reads == {}
      then "git-branchless writes it and never reads it"
      else null;
  in
    exclusions.${key} or derived;

  isFamily = lib.hasSuffix ".<name>";
  pathOf = key: lib.splitString "." (lib.removeSuffix ".<name>" key);

  # key → node → { type; untyped; }
  typeOf = key: node: let
    t = node.type or null;
    base =
      if t == "enum" && (node.values or []) != []
      then types.enum (map (v: v.value) node.values)
      else scalarTypes.${toString t} or null;
    refinement = refinements.${key} or null;
  in
    if refinement != null && refinement.type == t
    then {
      type =
        if isFamily key
        then refinement.refine node
        else types.nullOr (refinement.refine node);
      untyped = false;
    }
    else if base == null
    then {
      # A type the extractor grows later. The option still exists, but the
      # key is reported, so the generator check fails until someone maps it.
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

  describe = key: node:
    lib.concatStringsSep " " (
      [(node.description or "git-branchless `${key}`.")]
      ++ lib.optional (node.status or null == "legacy") "Deprecated upstream."
      ++ lib.optional (node.type or null == "enum")
      (lib.concatMapStringsSep "; " (v: "`${v.value}`: ${v.description or "no description upstream"}") node.values + ".")
      ++ (
        if node ? defaultDescription
        then ["git-branchless's default: ${node.defaultDescription}"]
        else if node ? default
        then ["git-branchless's default is `${builtins.toJSON node.default}`."]
        else lib.optional (!isFamily key) "git-branchless leaves it unset by default."
      )
      ++ lib.optional (node ? note) node.note
    );

  kept = lib.filterAttrs (key: node: excludedReason key node == null) extracted.settings;
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
    then throw "packages/git-branchless/lib/settings.nix: keys whose paths nest cannot both be options: ${lib.concatStringsSep ", " collisions}"
    else lib.foldl' lib.recursiveUpdate {} (lib.mapAttrsToList (key: node: lib.setAttrByPath (pathOf key) (option key node)) kept);

  stale = table: check:
    lib.sort (a: b: a < b) (lib.filter (key: !(extracted.settings ? ${key}) || !(check key extracted.settings.${key})) (builtins.attrNames table));
in {
  inherit leaves options;
  inherit (extracted) revsetFunctions;

  report = {
    inherit collisions;
    excluded = lib.mapAttrs excludedReason (lib.filterAttrs (key: node: excludedReason key node != null) extracted.settings);
    staleExclusions = stale exclusions (_: _: true);
    staleRefinements = stale refinements (key: node: refinements.${key}.type == (node.type or null));
    untyped = lib.sort (a: b: a < b) (builtins.attrNames (lib.filterAttrs (_: t: t.untyped) typed));
  };
}

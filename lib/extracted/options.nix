# Typed options from an extracted node tree: the reconciled entries of one
# surface (`(reconcile …).<surface>.entries`), keyed by path in the shared
# grammar of lib/extracted/go/nat_shared_test.go — `.` between keys, `[]` for
# a list element, `.<name>` for a map value — and typed in its vocabulary.
# It needs only nixpkgs lib, like reconcile, so an option module can call it
# before `pkgs` exists. Design: dev/fragments/extracted/typed-settings.md.
#
# Every option is `nullOr T` with `default = null`; null leaves the key out of
# the rendered file, so the tool applies its own default. Objects are closed
# submodules: a key upstream removes fails a consumer that still sets it. A
# node carrying the annotation field `secret` takes only a redact reference.
#
# Arguments:
#   nodes        path → node: `type`, and optionally `description`, `enum`,
#                `secret`, `template`; any other field fails
#                evaluation unless `unread` names it, so an extractor that
#                learns a fact must teach this generator too
#   tool         the program's name, used in descriptions
#   exclusions   path → reason it has no option
#   refinements  path → { type; refine; }: `refine {node; types;}` returns the
#                value type for a node of the node `type` the row was written
#                for; `types` is lib.types plus `duration` and `json`. A row on
#                a node with a secret descendant fails evaluation
#                when it would apply (same node type, node not itself secret).
#   unread       node fields the owner's extractor writes and no option reads
#
# Returns:
#   options  the root option declarations; `type` is their closed submodule
#   report   { misplaced; staleExclusions; staleRefinements; untyped; },
#            every list empty for a current owner
#   sample   { overrides ? {} }: one value for every non-excluded leaf, a list
#            or map holding one element, a secret a dummy reference; an
#            override (path → value) replaces the value at its path. For a
#            check that feeds the render to the tool's own loader.
{lib}: let
  inherit (lib) types;
  redact = import ../redact {inherit lib;};

  # time.ParseDuration's grammar: an optional sign, then `0` or one or more
  # decimal numbers each with a unit (ns, us, µs, μs, ms, s, m, h).
  duration = types.strMatching "[-+]?(0|(([0-9]+(\\.[0-9]*)?|\\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+)" // {description = "Go duration (time.ParseDuration: `300ms`, `1.5h`, `2h45m`)";};
  # Any JSON value; the type of `pkgs.formats.json {}`, which needs `pkgs`.
  json =
    types.nullOr (types.oneOf [types.bool types.int types.float types.str (types.attrsOf json) (types.listOf json)])
    // {description = "JSON value";};
  scalars = {
    inherit (types) bool int number;
    inherit duration;
    string = types.str;
  };
  known = ["description" "enum" "secret" "template" "type"];
in
  {
    nodes,
    tool,
    exclusions ? {},
    refinements ? {},
    unread ? [],
  }: let
    unknown = lib.concatLists (lib.mapAttrsToList (path: node:
      map (field: "${path}: unknown field `${field}`") (lib.subtractLists (known ++ unread) (builtins.attrNames node)))
    nodes);
    # A refinement returns the WHOLE value type of its node, so on a container
    # it replaces the generated type of every descendant, a redacted one
    # included, and lets a plaintext secret through. A row that would apply
    # (see fits) on a node with a secret descendant is refused.
    secretsUnder = path:
      lib.filter (other: (lib.hasPrefix "${path}." other || lib.hasPrefix "${path}[]" other) && nodes.${other} ? secret) (builtins.attrNames nodes);
    # Whether a row applies to `tree`; `widening` asks of the raw nodes,
    # `refinementFits` of the checked ones, so reading the latter forces the
    # throws in `checked`.
    fits = tree: path: row: tree ? ${path} && row.type == tree.${path}.type && !(tree.${path} ? secret);
    widening = lib.concatLists (lib.mapAttrsToList (path: row:
      lib.optionals (fits nodes path row)
      (map (secret: "${path} -> ${secret}") (secretsUnder path)))
    refinements);
    checked =
      if unknown != []
      then throw "lib/extracted/options: ${tool} nodes carry fields this generator does not read:\n  ${lib.concatStringsSep "\n  " unknown}"
      else if widening != []
      then throw "lib/extracted/options: ${tool} refinement rows sit on a node with a secret descendant, so their type could replace the redacted one (row path -> secret path):\n  ${lib.concatStringsSep "\n  " widening}"
      else nodes;

    # "" for a root node.
    parentOf = path: let
      keyed = builtins.match "(.*)\\.[^.]+" path;
    in
      if lib.hasSuffix "[]" path
      then lib.removeSuffix "[]" path
      else if keyed == null
      then ""
      else lib.head keyed;
    children = lib.groupBy parentOf (builtins.attrNames checked);
    childrenOf = path: lib.filter (child: !(exclusions ? ${child})) (children.${path} or []);
    element = path: "${path}[]";
    value = path: "${path}.<name>";

    # A node whose parent is missing, or is not a container that holds it,
    # would be dropped silently. Children of an `any` node are consumed by it.
    holds = parent: path: let
      segment = lib.removePrefix parent path;
    in
      {
        any = true;
        list = path == element parent;
        map = path == value parent;
        object = lib.hasPrefix "." segment && segment != ".<name>";
      }
      .${
        checked.${parent}.type
      }
      or false;
    placed = lib.mapAttrs (path: _: let
      parent = parentOf path;
    in
      parent == "" || (checked ? ${parent} && placed.${parent} && holds parent path))
    checked;

    refinementFits = fits checked;
    untypedReason = path: let
      node = checked.${path};
      inherit (node) type;
    in
      if refinements ? ${path} && refinementFits path refinements.${path}
      then null
      else if node ? secret || type == "any" || type == "object" || scalars ? ${type}
      then null
      else if type == "list" && !(checked ? ${element path})
      then "a list with no `${element path}` node"
      else if type == "map" && !(checked ? ${value path})
      then "a map with no `${value path}` node"
      else if type == "list" || type == "map"
      then null
      else "no option type for node type `${type}`";

    # path → the value type, before nullOr. A secret is always a reference: a
    # refinement row on a secret node is stale, so no row can widen it.
    typeOf = path: let
      node = checked.${path};
      t = node.type;
    in
      if refinements ? ${path} && refinementFits path refinements.${path}
      then
        refinements.${path}.refine {
          inherit node;
          types = types // {inherit duration json;};
        }
      else if node ? secret
      then redact.types.redacted
      else if t == "object"
      then types.submodule {options = optionsOf path;}
      else if t == "list"
      then types.listOf (nullableTypeOf (element path))
      else if t == "map"
      then types.attrsOf (nullableTypeOf (value path))
      else if t == "any"
      then json
      else if node ? enum
      then types.enum node.enum
      else scalars.${t} or types.unspecified;

    nullableTypeOf = path: types.nullOr (typeOf path);

    code = v: "`${builtins.toJSON v}`";
    describe = path: let
      node = checked.${path};
    in
      lib.concatStringsSep "\n\n" (
        lib.optional (node ? description) node.description
        ++ lib.optional (node ? template) "Upstream template: ${node.template}"
        ++ lib.optional (node ? enum) "One of ${lib.concatMapStringsSep ", " code node.enum}."
        ++ lib.optional (node ? secret) "A secret (${node.secret}); it takes a redact reference only, lifted out of the rendered file."
        ++ [
          "Null leaves it unset, so ${tool} applies its own default."
        ]
      );

    optionsOf = parent:
      lib.listToAttrs (map (path: {
          name = lib.removePrefix "${lib.optionalString (parent != "") "${parent}."}" path;
          value = lib.mkOption {
            type = nullableTypeOf path;
            default = null;
            description = describe path;
          };
        })
        (childrenOf parent));

    sampleOf = overrides: path: let
      node = checked.${path};
      t = node.type;
    in
      overrides.${
        path
      }
      or (
        if node ? secret
        then redact.file "/run/secrets/sample"
        else if t == "object"
        then sampleTree overrides path
        else if t == "list"
        then [(sampleOf overrides (element path))]
        else if t == "map"
        then {sample = sampleOf overrides (value path);}
        else if node ? enum
        then lib.head node.enum
        else
          {
            any = "sample";
            bool = true;
            duration = "1s";
            int = 1;
            number = 1.5;
            string = "sample";
          }
          .${
            t
          }
      );
    sampleTree = overrides: parent:
      lib.listToAttrs (map (path: {
          name = lib.removePrefix "${lib.optionalString (parent != "") "${parent}."}" path;
          value = sampleOf overrides path;
        })
        (childrenOf parent));

    sorted = lib.sort builtins.lessThan;
  in rec {
    options = optionsOf "";
    type = types.submodule {inherit options;};
    report = {
      misplaced = sorted (builtins.attrNames (lib.filterAttrs (_: ok: !ok) placed));
      staleExclusions = sorted (builtins.attrNames (lib.filterAttrs (path: _: !(checked ? ${path})) exclusions));
      staleRefinements = sorted (builtins.attrNames (lib.filterAttrs (path: row: !(refinementFits path row)) refinements));
      untyped = sorted (lib.filter (path: untypedReason path != null) (builtins.attrNames checked));
    };
    sample = {overrides ? {}}: let
      stale = lib.filter (path: !(checked ? ${path})) (builtins.attrNames overrides);
    in
      if stale == []
      then sampleTree overrides ""
      else throw "lib/extracted/options: ${tool} sample overrides name no node: ${lib.concatStringsSep ", " stale}";
  }

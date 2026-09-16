# Isolated, bounded Gate 2 prototype; not a production export.
{
  lib,
  grammar,
}: let
  g = grammar.dsl;
  fail = message: throw "gate2: ${message}";
  require = condition: message: value:
    if condition
    then value
    else fail message;
  tagged = tag: x: builtins.isAttrs x && (x._tag or null) == tag;
  names = builtins.attrNames;
  inherit (lib) concatMap;
  inherit (lib) mapAttrs;
  elemRef = e: require (tagged "element" e) "expected element declaration" e.ref;
  fieldRef = f: require (tagged "field" f) "expected field declaration" f.ref;
  relRef = r: require (tagged "relation" r) "expected authored relation declaration" r.ref;
  node = n: require (tagged "node" n) "expected runtime node, not element declaration" n;
  predicate = p: require (tagged "boolean-expression" p) "callback must return a predicate description, not a raw Nix Boolean" p;
  expression = op: args: {
    _tag = "boolean-expression";
    inherit op args;
  };
  candidate = {
    from = "candidate";
    schema = "sdoc-policy.model/v1";
  };
  rule = id: contract: config: extra:
    {
      inherit id config;
      contract = "sdoc-policy.${contract}/v1";
      scope = "model";
      inputs = {inherit candidate;};
      needs = [];
      after = [];
    }
    // extra;
  fieldName = f:
    if tagged "semantic-field" f
    then f.name
    else f.${builtins.head (names f)}.title;
  fieldType = f:
    if tagged "semantic-field" f
    then f.semantic.type
    else "native";
  cleanNode = n: builtins.removeAttrs (node n) ["_tag" "relations"];
  cleanExpr = p: let checked = predicate p; in {inherit (checked) op args;};
  exactlyOne = cardinality: cardinality != null && cardinality.min == 1 && cardinality.max == 1;
  semanticField = kind: name: options: let
    t = lib.types;
    valueType =
      if kind == "boolean"
      then t.bool
      else t.str;
    checked =
      (lib.evalModules {
        modules = [
          {
            options = {
              required = lib.mkOption {
                type = t.bool;
                default = false;
              };
              default = lib.mkOption {
                default = null;
                type = t.nullOr (t.attrTag {
                  literal = lib.mkOption {type = valueType;};
                  script = lib.mkOption {
                    type = t.submodule {
                      options = {
                        argv = lib.mkOption {type = t.nonEmptyListOf t.str;};
                        timeoutMs = lib.mkOption {type = t.ints.positive;};
                      };
                    };
                  };
                });
              };
            };
          }
          options
        ];
      }).config;
    native =
      (
        if checked.required
        then g.field.required
        else x: x
      )
      (
        if kind == "boolean"
        then g.field.one name ["false" "true"]
        else g.field.str name
      );
    semantic =
      {
        type = kind;
        presence =
          if checked.required
          then "required"
          else "optional";
        multiplicity = "single";
      }
      // lib.optionalAttrs (kind == "boolean") {
        encode = {
          false = "false";
          true = "true";
        };
        decode = {
          inherit false;
          inherit true;
        };
        invalid = "error";
      };
  in
    builtins.deepSeq checked {
      _tag = "semantic-field";
      inherit name native semantic;
      inherit (checked) default;
    };
  relationId = grammarId: element: nativeType: role: "${grammarId}/element/${element}/relation/${nativeType}/${role}";
  symbolicRelation = r: {
    _tag = "relation-subject";
    select = relRef r;
    owner = {
      _tag = "node";
      term = "owner";
      element = {
        grammar = r.ref.grammar;
        element = r.ref.ownerElement;
      };
    };
    target = {
      _tag = "node";
      term = "target";
      element = null;
    };
  };
  symbolicRecord = e: {
    _tag = "node";
    term = "record";
    element = elemRef e;
    relations = mapAttrs (_: kinds:
      mapAttrs (_: r: {
        _tag = "collection";
        select = relRef r;
        inherit (r) cardinality id;
        owner = {
          _tag = "node";
          term = "record";
          element = elemRef e;
        };
      })
      kinds)
    e.relations;
  };
  boundary = v: let
    p = predicate (v.closed {
      _tag = "node";
      term = "boundary";
      element = elemRef v.hierarchy.nodes;
    });
  in
    require (p.op == "fieldValue") "bounded boundary requires a semantic Boolean field expression" {
      field = p.args.field;
      semanticType = "boolean";
      open = ["false"];
      closed = ["true"];
    };
  hierarchyInput = visibility: {
    from = "view:${visibility.hierarchy.id}";
    schema = "sdoc-policy.forest/v1";
  };
  expressionRequirements = value:
    if builtins.isList value
    then lib.concatMap expressionRequirements value
    else if builtins.isAttrs value
    then
      (lib.optional (builtins.elem (value.op or null) ["canSee" "canDescend"]) {
        after = [value.args.valid];
        input = value.args.hierarchy;
      })
      ++ (lib.optional (value ? after) {inherit (value) after;})
      ++ lib.concatMap expressionRequirements (builtins.attrValues (builtins.removeAttrs value ["after"]))
    else [];
  expressionDependencies = requirements: lib.unique (lib.concatMap (r: r.after) requirements);
  expressionInputs = requirements: let
    inputs = map (r: r.input) (builtins.filter (r: r ? input) requirements);
    identities = lib.unique (map (input: input.from) inputs);
  in
    builtins.listToAttrs (map (identity: let
      definitions = builtins.filter (input: input.from == identity) inputs;
    in
      require (lib.all (input: input == builtins.head definitions) definitions)
      "conflicting expression view input definitions" {
        name = identity;
        value = builtins.head definitions;
      })
    identities);
  lowerPredicate = id: subject: callback: let
    isRelation = tagged "relation" subject;
    symbolic =
      if isRelation
      then symbolicRelation subject
      else symbolicRecord subject;
    p = predicate (callback symbolic);
    select =
      if isRelation
      then relRef subject
      else null;
    records =
      if isRelation
      then null
      else elemRef subject;
  in
    if p.op == "isNodeType" && isRelation && p.args.node.term == "target"
    then
      rule id "targets" {
        inherit select;
        allowed = [p.args.element];
      }
      {needs = ["model.resolved-endpoints/v1"];}
    else if p.op == "canSee" && isRelation
    then
      require (p.args.origin == cleanNode symbolic.owner && p.args.target == cleanNode symbolic.target)
      "bounded visible lowering supports exactly authored owner to target; reversed operands require another contract"
      (rule id "visible" {
          inherit select;
          boundary = p.args.boundary;
        }
        {
          inputs = {
            inherit candidate;
            hierarchy = p.args.hierarchy;
          };
          after = [p.args.valid];
        })
    else if p.op == "canDescend" && !isRelation
    then
      require (p.args.origin.term
        == "only-target"
        && p.args.target.term == "only-target"
        && p.args.origin.select.nativeType == "Parent"
        && p.args.target.select.nativeType == "Child"
        && p.args.origin.select.ownerElement == records.element
        && p.args.target.select.ownerElement == records.element
        && p.args.origin.select.grammar == records.grammar
        && p.args.target.select.grammar == records.grammar)
      "bounded record path requires two explicit singleton endpoints"
      (rule id "endpoint-path" {
          inherit records;
          upper = p.args.origin.select;
          lower = p.args.target.select;
          boundary = p.args.boundary;
        } {
          inputs = {
            inherit candidate;
            hierarchy = p.args.hierarchy;
          };
          after = lib.unique ([p.args.valid] ++ p.args.origin.after ++ p.args.target.after);
        })
    else
      rule id "predicate" {
        quantification =
          if isRelation
          then "each-authored-occurrence"
          else "each-record";
        subject =
          if isRelation
          then select
          else records;
        expression = cleanExpr p;
      } (let
        requirements = expressionRequirements p;
      in {
        after = expressionDependencies requirements;
        inputs = {inherit candidate;} // expressionInputs requirements;
      });
  lowerOn = subject: constraints:
    require (tagged "relation" subject || tagged "element" subject) "on needs a declaration subject"
    (map (name: lowerPredicate "${subject.id}/constraint/${name}" subject constraints.${name}) (names constraints));
  constraint = rec {
    exactly = count:
      require (builtins.isInt count && count >= 0) "invalid exact cardinality" {
        min = count;
        max = count;
      };
    atMost = count:
      require (builtins.isInt count && count >= 0) "invalid maximum cardinality" {
        min = 0;
        max = count;
      };
    isNodeType = n: e:
      expression "isNodeType" {
        node = cleanNode n;
        element = elemRef e;
      };
    sameNodeType = a: b:
      expression "sameNodeType" {
        left = cleanNode a;
        right = cleanNode b;
      };
    eq = a: b:
      expression "eqNode" {
        left = cleanNode a;
        right = cleanNode b;
      };
    constant = b: require (builtins.isBool b) "constant requires Boolean" (expression "constant" {value = b;});
    allOf = ps: expression "allOf" {predicates = map cleanExpr ps;};
    anyOf = ps: expression "anyOf" {predicates = map cleanExpr ps;};
    fieldValue = n: f:
      require ((node n).element == {inherit (f.ref) grammar element;} && f.semanticType == "boolean")
      "fieldValue needs a Boolean field belonging to the runtime node's element"
      (expression "fieldValue" {
        node = cleanNode n;
        field = fieldRef f;
      });
    only = collection:
      require (tagged "collection" collection && exactlyOne collection.cardinality)
      "only requires an explicit exactly-one cardinality guarantee"
      {
        target = {
          _tag = "node";
          term = "only-target";
          element = null;
          inherit (collection) select;
          after = ["${collection.id}/cardinality"];
        };
      };
    forest = args: {
      _tag = "forest-definition";
      inherit (args) nodes edges;
    };
    boundaryVisibility = args: {
      _tag = "visibility-definition";
      inherit (args) hierarchy closed;
    };
    nativeDag = {_tag = "native-dag-definition";};
    projection = id: args: {
      inherit id;
      inherit (args) elementType ownedRelations;
      fieldsWhenPresent = map fieldRef args.fieldsWhenPresent;
    };
    preserve = args: {
      _tag = "preserve-definition";
      inherit (args) baseline projection;
    };
    on = subject: constraints: {
      rules = lowerOn subject constraints;
      views = [];
    };
  };
  schema = {
    default.literal = value: {literal = value;};
    default.script = script: {inherit script;};
    field.boolean = semanticField "boolean";
    field.string = semanticField "string";
    baseline = id: {
      from = "fact:${id}";
      schema = "sdoc-policy.baseline/v1";
    };
    grammar = grammarId: body: let
      declaration = body {inherit elements views;};
      definitions = mapAttrs (name: build: build elements.${name}) declaration.elements;
      elements =
        mapAttrs (name: def: {
          _tag = "element";
          id = "${grammarId}/element/${name}";
          ref = {
            grammar = grammarId;
            element = name;
          };
          fields = builtins.listToAttrs (map (f: {
              name = fieldName f;
              value = {
                _tag = "field";
                ref = {
                  grammar = grammarId;
                  element = name;
                  name = fieldName f;
                };
                semanticType = fieldType f;
              };
            })
            def.fields);
          relations = mapAttrs (role: kinds:
            mapAttrs (kind: rel: let
              nativeType =
                if kind == "parent"
                then "Parent"
                else if kind == "child"
                then "Child"
                else fail "unsupported relation kind";
            in {
              _tag = "relation";
              id = relationId grammarId name nativeType role;
              ref = {
                grammar = grammarId;
                ownerElement = name;
                inherit nativeType role;
              };
              cardinality = rel.cardinality or null;
            })
            kinds) (def.relations or {});
        })
        definitions;
      viewDefinitions = declaration.views or {};
      views = mapAttrs (name: def: let
        id = "${grammarId}/view/${name}";
      in
        if tagged "forest-definition" def
        then {
          _tag = "forest";
          inherit id;
          inherit (def) nodes;
          ref = {
            inherit id;
            schema = "sdoc-policy.forest/v1";
          };
        }
        else if tagged "visibility-definition" def
        then let
          call = op: origin: target:
            expression op {
              inherit (def.hierarchy) id;
              origin = cleanNode origin;
              target = cleanNode target;
              boundary = boundary def;
              hierarchy = hierarchyInput def;
              valid = "${def.hierarchy.id}/valid";
            };
        in {
          _tag = "visibility";
          inherit id;
          canSee = call "canSee";
          canDescend = call "canDescend";
        }
        else fail "unknown view definition")
      viewDefinitions;
      native = map (name: let
        def = definitions.${name};
        fields = map (f:
          if tagged "semantic-field" f
          then f.native
          else f)
        def.fields;
        fieldNames = map fieldName def.fields;
        relations = concatMap (role:
          map (kind: g.rel.${kind} role definitions.${name}.relations.${role}.${kind}.reverseRole)
          (names definitions.${name}.relations.${role})) (names (def.relations or {}));
      in
        require (builtins.length fieldNames == builtins.length (lib.unique fieldNames)) "duplicate ordered field declaration"
        (g.el name {} ({inherit fields;} // lib.optionalAttrs (relations != []) {inherit relations;}))) (names definitions);
      metadataFields = concatMap (name:
        map (f: {
          field = {
            grammar = grammarId;
            element = name;
            inherit (f) name;
          };
          inherit (f) default native semantic;
        }) (builtins.filter (tagged "semantic-field") definitions.${name}.fields)) (names definitions);
      metadata = {
        schema = "sdoc-policy.semantic-types/v1";
        fields = metadataFields;
      };
      elementRules = concatMap (name: let
        e = elements.${name};
        def = definitions.${name};
      in
        lowerOn e (def.constraints or {})
        ++ concatMap (role:
          concatMap (kind: let
            r = e.relations.${role}.${kind};
            rd = def.relations.${role}.${kind};
          in
            lowerOn r (rd.constraints or {})
            ++ lib.optional (r.cardinality != null)
            (rule "${r.id}/cardinality" "count" {
              records = elemRef e;
              select = relRef r;
              inherit (r.cardinality) min max;
            } {})) (names e.relations.${role})) (names e.relations)) (names elements);
      forestRules = concatMap (name: let
        def = viewDefinitions.${name};
      in
        lib.optional (tagged "forest-definition" def)
        (rule "${views.${name}.id}/valid" "forest-valid" {
          nodes = elemRef def.nodes;
          select = map relRef def.edges;
        } {})) (names views);
      forestViews = concatMap (name: let
        def = viewDefinitions.${name};
      in
        lib.optional (tagged "forest-definition" def) {
          id = views.${name}.id;
          contract = "sdoc-policy.forest-view/v1";
          config = {
            nodes = elemRef def.nodes;
            select = map relRef def.edges;
          };
          inputs = {inherit candidate;};
          after = ["${views.${name}.id}/valid"];
          needs = [];
          schema = "sdoc-policy.forest/v1";
        }) (names views);
      globalRules = map (name: let
        def = declaration.constraints.${name};
        id = "${grammarId}/constraint/${name}";
      in
        if tagged "native-dag-definition" def
        then rule id "native-dag" {} {needs = ["model.resolved-parent-child/v1" "native.all-role-dag/v1"];}
        else if tagged "preserve-definition" def
        then
          rule id "preserve" {inherit (def) projection;}
          {
            inputs = {
              inherit candidate;
              inherit (def) baseline;
            };
          }
        else fail "unknown global constraint") (names (declaration.constraints or {}));
      normalized = {
        grammar = grammar.check.elements native;
        bundle = {
          declarations = map (name: {
            id = elements.${name}.id;
            kind = "element-declaration";
            native = grammar.check.element (builtins.head (builtins.filter (e: e.tag == name) native));
            semanticFields = builtins.filter (f: f.field.element == name) metadataFields;
          }) (names elements);
          rules = elementRules ++ forestRules ++ globalRules;
          views = forestViews;
        };
        semanticTypes = metadata // {digest = builtins.hashString "sha256" (builtins.toJSON metadata);};
      };
    in {
      inherit elements views normalized;
      rendered = grammar.render normalized.grammar;
    };
  };
in {inherit constraint schema;}

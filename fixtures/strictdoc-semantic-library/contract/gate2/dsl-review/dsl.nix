# Evaluation-only lowering, adapted from the supplied stub. No graph evaluator.
let
  inherit
    (builtins)
    attrNames
    concatLists
    elem
    filter
    foldl'
    head
    isAttrs
    isBool
    isFunction
    isList
    length
    map
    mapAttrs
    removeAttrs
    ;
  native = import ../../../../../packages/strictdoc-grammar/lib/dsl.nix {lib = {inherit mapAttrs;};};
  unique = xs:
    foldl' (acc: x:
      if elem x acc
      then acc
      else acc ++ [x]) []
    xs;
  cleanField = f: removeAttrs f ["_semantic" "_default"];
  fieldBody = f: let n = cleanField f; in n.${head (attrNames n)};
  cleanRel = r: removeAttrs r ["__functor" "_inline"];
  direction = r: head (attrNames (cleanRel r));
  role = r: (cleanRel r).${direction r}.role or "@file";
  sym = op: args: {
    _op = op;
    inherit args;
  };
  count = collection: sym "count" [collection];
  lt = left: right: sym "lt" [left right];
  lte = left: right: sym "lte" [left right];
  gt = left: right: sym "gt" [left right];
  gte = left: right: sym "gte" [left right];
  eq = left: right: sym "eq" [left right];
  check = name: expr: {inherit name expr;};
  on = subject: rule: {
    _on = true;
    inherit subject rule;
  };
  declaration = kind: name: config: {
    _kind = kind;
    inherit name config;
  };
  relationRef = nativeType: owner: name: {
    _ref = "relation";
    element = owner.tag;
    inherit nativeType name;
  };
  parentOf = relationRef "parent";
  childOf = relationRef "child";
  fieldOf = owner: f: {
    _ref = "field";
    element = owner.tag;
    name = (fieldBody f).title;
  };
  extendRel = r:
    r
    // {
      _inline = [];
      __functor = _value: predicate:
        r
        // {
          _inline = [
            (
              if isFunction predicate
              then check "predicate" predicate
              else predicate
            )
          ];
        };
    };
  field =
    native.field
    // {
      required = f:
        (native.field.required (cleanField f))
        // (builtins.intersectAttrs {
            _semantic = null;
            _default = null;
          }
          f);
      boolean = name:
        (native.field.one name ["false" "true"])
        // {
          _semantic = {
            type = "boolean";
            codec = [
              {
                native = "false";
                semantic = false;
              }
              {
                native = "true";
                semantic = true;
              }
            ];
          };
        };
      creationDefault = value: f:
        if (f._semantic.type or null) == "boolean" && isBool value
        then f // {_default = {literal = value;};}
        else throw "creationDefault: this stub supports typed Boolean literals";
    };
  rel =
    native.rel
    // {
      parent = a: b: extendRel (native.rel.parent a b);
      child = a: b: extendRel (native.rel.child a b);
    };
  el = name: props: body: (native.el name props body) // {_kind = "element";};
  model = name: body:
    {
      inherit name;
      elements = [];
      views = [];
      inputs = [];
      projections = [];
      constraints = [];
      contributions = [];
    }
    // body;
  normalize = g: let
    escape = builtins.replaceStrings ["%" "/"] ["%25" "%2F"];
    root = "model:${escape g.name}";
    elementId = name: "${root}/element:${escape name}";
    refId = r:
      if r._ref == "relation"
      then "${elementId r.element}/relation:${r.nativeType}:${escape r.name}"
      else "${elementId r.element}/field:${escape r.name}";
    declId = d:
      if d._kind == "element"
      then elementId d.tag
      else "${root}/${d._kind}:${escape d.name}";
    relationIds = concatLists (map (e:
      map
      (r: refId (relationRef (direction r) e (role r))) (e.relations or []))
    g.elements);
    allIds =
      (map declId (g.elements ++ g.views ++ g.inputs ++ g.projections))
      ++ relationIds
      ++ concatLists (map (e: map (f: refId (fieldOf e f)) (e.fields or [])) g.elements);
    reference = value: let
      id =
        if value ? _ref
        then refId value
        else declId value;
      kind =
        value._ref or value._kind;
    in
      if elem id allIds
      then {
        ref = kind;
        inherit id;
      }
      else throw "undeclared ${kind} reference: ${id}";
    bad = ctx: value: throw "check \"${ctx.name}\" at ${ctx.id}: expected symbolic predicate, got ${builtins.typeOf value}";
    lowerValue = ctx: value:
      if isAttrs value && (value ? _ref || value ? _kind)
      then reference value
      else if isAttrs value && value ? _op
      then lowerExpr ctx value
      else if isList value
      then map (lowerValue ctx) value
      else if isAttrs value
      then mapAttrs (_: lowerValue ctx) value
      else if isFunction value
      then bad ctx value
      else value;
    lowerExpr = ctx: expr:
      if isFunction expr
      then
        if ctx.scope != "relation"
        then throw "check \"${ctx.name}\": relation predicate at ${ctx.scope} scope"
        else
          lowerExpr ctx (expr {
            origin = sym "origin" [ctx.subject];
            target = sym "target" [ctx.subject];
          })
      else if !(isAttrs expr && expr ? _op)
      then bad ctx expr
      else if expr._op == "record"
      then
        if ctx.scope != "record"
        then throw "check \"${ctx.name}\": record binder at ${ctx.scope} scope"
        else let
          binder = "${ctx.id}#record";
          collection = nativeType: name: sym "relationCollection" [(sym "binderRef" [binder]) nativeType name];
        in {
          op = "record";
          inherit binder;
          body = lowerExpr ctx (expr.bind {
            parents = collection "parent";
            children = collection "child";
          });
        }
      else if expr._op == "const"
      then {
        op = "const";
        value = head expr.args;
      }
      else {
        op = expr._op;
        args =
          map
          (arg:
            if isBool arg
            then bad ctx arg
            else lowerValue ctx arg)
          expr.args;
      };
    inputRefs = value:
      if isList value
      then concatLists (map inputRefs value)
      else if isAttrs value && (value.ref or null) == "input"
      then [value.id]
      else if isAttrs value
      then concatLists (map inputRefs (builtins.attrValues value))
      else [];
    lowerCheck = scope: subject: source: ck:
      if ck ? _on
      then lowerCheck "relation" (reference ck.subject) source ck.rule
      else let
        id = "${subject.id}/check:${escape ck.name}";
        ctx = {
          inherit id scope subject;
          inherit (ck) name;
        };
        expr = lowerExpr ctx ck.expr;
      in
        ctx
        // {
          inherit expr;
          inputs = unique (["candidate"] ++ inputRefs expr);
          origins = [
            (
              if source == null
              then "declaration:${subject.id}"
              else source
            )
          ];
        };
    elementChecks = e: let
      subject = reference e;
      inline = concatLists (map (r:
        map
        (lowerCheck "relation" (reference (relationRef (direction r) e (role r))) null)
        (r._inline or [])) (e.relations or []));
    in
      inline ++ map (lowerCheck "record" subject null) (e.constraints or []);
    lowered =
      concatLists (map elementChecks g.elements)
      ++ map (lowerCheck "model" {
          ref = "model";
          id = root;
        }
        null)
      g.constraints
      ++ concatLists (map (k:
        map (lowerCheck "relation" (reference k.subject)
          "contribution:${k.name}")
        k.checks)
      g.contributions);
    # Compare only lowered records. Authoring values can be recursive or callable.
    rules = map (id: let
      group = filter (r: r.id == id) lowered;
      first = head group;
      meanings = unique (map (r: removeAttrs r ["origins"]) group);
    in
      if length meanings == 1
      then
        first
        // {
          origins = unique (concatLists (map (r: r.origins) group));
        }
      else throw "conflicting definitions for check \"${first.name}\" at ${id}")
    (unique (map (r: r.id) lowered));
    lowerNative = e:
      (removeAttrs e ["_kind" "constraints" "fields" "relations"])
      // {
        fields = map cleanField (e.fields or []);
        relations =
          if (e.relations or []) == []
          then null
          else map cleanRel e.relations;
      };
    metadata = e: let
      schema = "semantic-types/v1";
      fields = map (f: {
        field = refId (fieldOf e f);
        native = cleanField f;
        semantic = f._semantic or {type = head (attrNames (cleanField f));};
        default = f._default or null;
      }) (e.fields or []);
    in {
      inherit schema fields;
      grammar = root;
      element = elementId e.tag;
      digest = builtins.hashString "sha256" (builtins.toJSON {inherit schema fields;});
      defaultsApply = "surviving-new-record-final-absence-only";
    };
    lowerDecl = d: {
      id = declId d;
      kind = d._kind;
      inherit (d) name;
      config =
        lowerValue {
          inherit (d) name;
          id = declId d;
        }
        d.config;
    };
    declarations = concatLists (map (e:
      [
        {
          id = elementId e.tag;
          kind = "element";
          name = e.tag;
        }
      ]
      ++ map (r: {
        id = refId (relationRef (direction r) e (role r));
        kind = "relation";
        owner = elementId e.tag;
        nativeType = direction r;
        name = role r;
      }) (e.relations or []))
    g.elements);
  in
    if length allIds != length (unique allIds)
    then throw "duplicate declaration identity"
    else {
      grammar = map lowerNative g.elements;
      semanticTypes = map metadata g.elements;
      bundle = {
        schema = "semantic-constraints/v1";
        id = root;
        inherit declarations rules;
        views = map lowerDecl g.views;
        inputs = map lowerDecl g.inputs;
        projections = map lowerDecl g.projections;
      };
    };
in {
  inherit el field rel model normalize check on parentOf childOf fieldOf;
  inherit count lt lte gt gte eq;
  contribute = name: subject: checks: {inherit name subject checks;};
  record = bind: {
    _op = "record";
    inherit bind;
  };
  isNodeType = node: element: sym "isNodeType" [node element];
  atMost = n: c: lte (count c) n;
  atLeast = n: c: gte (count c) n;
  exactly = n: c: eq (count c) n;
  only = collection: let
    singleton = sym "only" [collection];
  in
    singleton // {target = sym "endpointTarget" [singleton];};
  allOf = expressions: sym "allOf" expressions;
  const = value:
    if isBool value
    then sym "const" [value]
    else throw "const expects a Boolean";
  forest = name: edges:
    declaration "view" name {
      contract = "selected-forest/v1";
      inherit edges;
      vertices = {
        _kind = "element";
        tag = edges.element;
      };
      orientation = "parent-to-child";
      connected = false;
    };
  isForest = view: sym "isForest" [view];
  visibility = name: hierarchy: policy:
    declaration "view" name {
      contract = "origin-sensitive-visibility/v1";
      inherit hierarchy policy;
      sameRoot = true;
      path = "unique-hierarchy-path";
      zeroLength = true;
    };
  visible = view: origin: target: sym "visible" [view origin target];
  canDescend = view: origin: target: sym "canDescend" [view origin target];
  nativeDag = sym "nativeDag" ["all-native-parent-child-roles" "parent-to-child"];
  input = declaration "input";
  projection = declaration "projection";
  preserve = baseline: projection: sym "preserveListedRecords" [baseline projection];
}

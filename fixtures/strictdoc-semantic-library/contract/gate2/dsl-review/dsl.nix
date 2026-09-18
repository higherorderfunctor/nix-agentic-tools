# Evaluation-only lowering. Selectors and checks over named leaves; no graph evaluator.
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
  ruleKinds = ["target-type" "count" "field-value" "visible-target" "endpoint-path" "native-dag" "forest-validity" "preserve"];
  declarationKinds = ["model" "element" "field" "relation" "view" "input" "projection"];
  keywordSpaces = {
    ascent = ["unrestricted"];
    visit = ["always"];
    expand = ["open-or-origin-in-subtree-including-self"];
    orientation = ["parent-to-child"];
    connected = [false];
    relationOrder = ["set"];
    requireSingleton = [true];
    from = ["owner"];
    to = ["target"];
    subject = ["record" "owner" "target"];
    absentSatisfies = [false true];
    compare = ["lt" "lte" "gt" "gte" "eq"];
    direction = ["parent" "child"];
    kind = ruleKinds ++ declarationKinds ++ ["external-snapshot"];
    status = ["satisfied" "violated" "blocked" "error"];
    contract = ["selected-forest/v1" "origin-sensitive-visibility/v1"];
  };
  keyword = field: values: value:
    if elem value values
    then value
    else throw "invalid keyword ${field}: ${builtins.toJSON value}";
  validateKeyword = field: value: keyword field keywordSpaces.${field} value;
  validateKeywords = value:
    if isList value
    then map validateKeywords value
    else if isAttrs value
    then
      mapAttrs (name: child:
        if builtins.hasAttr name keywordSpaces
        then validateKeyword name child
        else validateKeywords child)
      value
    else value;
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
  role = r: (cleanRel r).${direction r}.role;
  # A File relation names a path, not a record, so it declares no owned
  # occurrence and carries no role or direction. It stays in the native grammar
  # and reaches no identity, selector, or check. Only File is dropped: every
  # other native key reaches the direction keyword space, which names it.
  ownedRelations = e: filter (r: direction r != "file") (e.relations or []);
  sym = op: fields: {_op = op;} // fields;
  count = collection: sym "count" {inherit collection;};
  # The field constructor names the field; it does not say which element
  # declares it. Only the selector knows that, so normalize checks the values
  # against the choices the subject's own element declares. What is local here
  # is the value list itself.
  fieldValue = f: values: let
    inherit (fieldBody f) title;
    foreign = filter (v: !(builtins.isString v)) values;
  in
    if values == []
    then throw "field value: ${title} needs at least one value"
    else if foreign != []
    then throw "field value: ${title} admits native strings only; one value is a ${builtins.typeOf (head foreign)}"
    else
      sym "fieldValue" {
        field = title;
        inherit values;
      };
  compare = op: left: right: sym op {inherit left right;};
  lt = compare "lt";
  lte = compare "lte";
  gt = compare "gt";
  gte = compare "gte";
  eq = compare "eq";
  all = terms:
    if isList terms
    then sym "all" {inherit terms;}
    else throw "all expects a list of predicates";
  any = terms:
    if isList terms
    then sym "any" {inherit terms;}
    else throw "any expects a list of predicates";
  not = term: sym "not" {inherit term;};
  where = subject: predicate: subject // {_where = predicate;};
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
              if isFunction predicate || (isAttrs predicate && predicate ? _op)
              then {expr = predicate;}
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
      choice = name: choices:
        (native.field.one name choices)
        // {_semantic = {type = "string";};};
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
      _kind = "model";
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
      else if d._kind == "model"
      then root
      else "${root}/${d._kind}:${escape d.name}";
    allIds =
      [root]
      ++ map declId (g.elements ++ g.views ++ g.inputs ++ g.projections)
      ++ concatLists (map (e:
        map (r: refId (relationRef (direction r) e (role r))) (ownedRelations e)
        ++ map (f: refId (fieldOf e f)) (e.fields or []))
      g.elements);
    fieldsOf = tag:
      concatLists (map (e:
        if e.tag == tag
        then map fieldBody (e.fields or [])
        else [])
      g.elements);
    reference = value: let
      id =
        if value ? _ref
        then refId value
        else declId value;
    in
      if elem id allIds
      then id
      else throw "undeclared reference: ${id}";
    # The element a selected subject belongs to; a model selector names none.
    elementOf = s:
      if scopeOf s == "relation"
      then s.element
      else if scopeOf s == "record"
      then s.tag
      else null;
    scopeOf = s:
      if (s._ref or null) == "relation"
      then "relation"
      else if (s._kind or null) == "element"
      then "record"
      else if (s._kind or null) == "model"
      then "model"
      else throw "selector must name a relation, element, or model";
    selectSubject = s:
      if scopeOf s == "relation"
      then {
        occurrences = {
          inherit (s) element;
          role = s.name;
          direction = s.nativeType;
        };
      }
      else if scopeOf s == "record"
      then {records = {element = s.tag;};}
      else {model = true;};
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
    lowerOperand = ctx: value:
      if isBool value
      then bad ctx value
      else if isList value
      then map (lowerOperand ctx) value
      else lowerValue ctx value;
    lowerExpr = ctx: expr:
      if isFunction expr
      then
        if ctx.scope != "relation"
        then throw "check \"${ctx.name}\": relation predicate at ${ctx.scope} scope"
        else
          lowerExpr ctx (expr {
            origin = "owner";
            target = "target";
          })
      else if !(isAttrs expr && expr ? _op)
      then bad ctx expr
      else if expr._op == "record"
      then
        if ctx.scope != "record"
        then throw "check \"${ctx.name}\": record binder at ${ctx.scope} scope"
        else let
          collection = direction: role:
            sym "relations" {
              record = "record";
              inherit direction role;
            };
        in
          lowerExpr ctx (expr.bind {
            parents = collection "parent";
            children = collection "child";
          })
      else if elem expr._op ["all" "any"]
      then {
        op = expr._op;
        terms = map (lowerExpr ctx) expr.terms;
      }
      else if expr._op == "not"
      then {
        op = "not";
        term = lowerExpr ctx expr.term;
      }
      else
        {op = expr._op;}
        // mapAttrs (_: value:
          if expr._op == "const"
          then lowerValue ctx value
          else lowerOperand ctx value)
        (removeAttrs expr (["_op"]
          ++ (
            if expr._op == "only"
            then ["target"]
            else []
          )));
    isOp = op: e: isAttrs e && (e.op or null) == op;
    isCollection = e: isOp "relations" e && e.record == "record";
    selector = e: {inherit (e) role direction;};
    isEndpoint = e:
      isOp "endpointTarget" e
      && isOp "only" e.relation
      && isCollection e.relation.collection;
    # A field-value leaf reads one record's field, so its values are the
    # choices that record's element declares. A record or owner subject fixes
    # the element at lowering; a target subject does not, so every element
    # declaring the name is a candidate and the wrong one blocks at evaluation.
    fieldValueLeaf = ctx: subject: absentSatisfies: leaf: let
      owners =
        if subject == "target"
        then map (each: each.tag) g.elements
        else [ctx.element];
      among =
        if subject == "target"
        then "any element"
        else ctx.element;
      declared = filter (b: b.title == leaf.field) (concatLists (map fieldsOf owners));
      admits = b: (b.choices or null) == null || filter (v: !(elem v b.choices)) leaf.values == [];
    in
      if declared == []
      then throw "check \"${ctx.name}\" at ${ctx.id}: the field ${leaf.field} is not declared on ${among}"
      else if !(builtins.any admits declared)
      then throw "check \"${ctx.name}\" at ${ctx.id}: ${builtins.toJSON leaf.values} is not a declared choice of ${leaf.field} on ${among}"
      else {
        kind = "field-value";
        inherit subject absentSatisfies;
        inherit (leaf) field values;
      };
    lowerPredicate = ctx: e: let
      inherit (ctx) scope;
    in
      if isOp "all" e || isOp "any" e
      then {${e.op} = map (lowerPredicate ctx) e.terms;}
      else if isOp "not" e
      then {not = lowerPredicate ctx e.term;}
      else if scope == "relation" && isOp "isNodeType" e && e.node == "target"
      then {
        kind = "target-type";
        targetElement = e.element;
      }
      else if
        scope
        == "record"
        && elem e.op ["lt" "lte" "gt" "gte" "eq"]
        && isOp "count" e.left
        && isCollection e.left.collection
        && builtins.isInt e.right
      then {
        kind = "count";
        relation = selector e.left.collection;
        compare = e.op;
        value = e.right;
      }
      else if isOp "fieldValue" e || isOp "ifPresent" e || isOp "at" e
      then let
        subject =
          if isOp "at" e
          then validateKeyword "subject" e.node
          else "record";
        inner =
          if isOp "at" e
          then e.term
          else e;
        absentSatisfies = isOp "ifPresent" inner;
        leaf =
          if absentSatisfies
          then inner.term
          else inner;
        wrong = throw "check \"${ctx.name}\" at ${ctx.id}: field value at ${subject} subject in ${scope} scope";
      in
        if !(isOp "fieldValue" leaf)
        then throw "check \"${ctx.name}\" at ${ctx.id}: at and ifPresent take one field value predicate"
        else if scope == "record" && subject != "record"
        then wrong
        else if scope == "relation" && subject == "record"
        then wrong
        else if scope == "model"
        then wrong
        else fieldValueLeaf ctx subject absentSatisfies leaf
      else if scope == "relation" && isOp "visible" e && e.origin == "owner" && e.target == "target"
      then {
        kind = "visible-target";
        inherit (e) view;
        from = "owner";
        to = "target";
      }
      else if scope == "record" && isOp "canDescend" e && isEndpoint e.origin && isEndpoint e.target
      then {
        kind = "endpoint-path";
        inherit (e) view;
        upper = selector e.origin.relation.collection;
        lower = selector e.target.relation.collection;
        requireSingleton = true;
      }
      else if scope == "model" && isOp "nativeDag" e
      then {kind = "native-dag";}
      else if scope == "model" && isOp "isForest" e
      then {
        kind = "forest-validity";
        inherit (e) view;
      }
      else if scope == "model" && isOp "preserve" e
      then {
        kind = "preserve";
        inherit (e) baseline projection;
      }
      else throw "check \"${ctx.name}\" at ${ctx.id}: unsupported ${e.op} predicate at ${scope} scope";
    inputIds = map declId g.inputs;
    inputRefs = value:
      if builtins.isString value
      then
        (
          if elem value inputIds
          then [value]
          else []
        )
      else if isList value
      then concatLists (map inputRefs value)
      else if isAttrs value
      then concatLists (map inputRefs (builtins.attrValues value))
      else [];
    lowerCheck = scope: sub: source: ck:
      if ck ? _on
      then lowerCheck (scopeOf ck.subject) ck.subject source ck.rule
      else let
        subjectId = reference sub;
        subjectName = sub.name or sub.tag;
        ctx = {
          inherit scope;
          element = elementOf sub;
          id = subjectId;
          name = ck.name or "${subjectName}.inline";
        };
        predicate = lowerPredicate ctx (lowerExpr ctx ck.expr);
        select =
          selectSubject sub
          // (
            if sub ? _where
            then {where = lowerPredicate ctx (lowerExpr ctx sub._where);}
            else {}
          );
        name = ck.name or "${subjectName}.${predicate.kind or (head (attrNames predicate))}";
      in {
        id = "${subjectId}/check:${escape name}";
        inherit name select;
        check = predicate;
        inputs = unique (["candidate"] ++ inputRefs [select predicate]);
        origins = [
          (
            if source == null
            then "declaration:${subjectId}"
            else source
          )
        ];
      };
    elementChecks = e:
      concatLists (map (r:
        map (lowerCheck "relation" (relationRef (direction r) e (role r)) null)
        (r._inline or [])) (ownedRelations e))
      ++ map (lowerCheck "record" e null) (e.constraints or []);
    lowered =
      concatLists (map elementChecks g.elements)
      ++ map (lowerCheck "model" {
          _kind = "model";
          inherit (g) name;
        }
        null)
      g.constraints
      ++ concatLists (map (k: map (lowerCheck "relation" k.subject "contribution:${k.name}") k.checks) g.contributions);
    # Compare complete lowered meanings; origins do not affect check identity.
    mergedRules = map (id: let
      group = filter (r: r.id == id) lowered;
      first = head group;
      meanings = unique (map (r: removeAttrs r ["origins"]) group);
    in
      if length meanings == 1
      then first // {origins = unique (concatLists (map (r: r.origins) group));}
      else throw "conflicting definitions for check \"${first.name}\" at ${id}")
    (unique (map (r: r.id) lowered));
    requireOne = field: matches:
      if length matches == 1
      then (head matches).id
      else throw "requires: ${field}: expected one prerequisite, found ${toString (length matches)}";
    views = map lowerDecl g.views;
    leaves = predicate:
      if predicate ? kind
      then [predicate]
      else if predicate ? not
      then leaves predicate.not
      else concatLists (map leaves (predicate.all or predicate.any));
    # Only positive conjuncts establish facts when a prerequisite rule succeeds.
    guaranteedLeaves = predicate:
      if predicate ? kind
      then [predicate]
      else if predicate ? all
      then concatLists (map guaranteedLeaves predicate.all)
      else [];
    hierarchyFor = rule: leaf: let
      view = head (filter (v: v.id == leaf.view) views);
    in
      if view.config.contract == "origin-sensitive-visibility/v1"
      then view.config.hierarchy
      else throw "requires: ${rule.id}: expected a visibility view";
    hasLeaf = predicate: rule: builtins.any predicate (guaranteedLeaves rule.check);
    forestFor = rule: leaf:
      requireOne "${rule.id} forest-validity"
      (filter (r:
        r.id
        != rule.id
        && r.select == {model = true;}
        && hasLeaf (l: l.kind == "forest-validity" && l.view == hierarchyFor rule leaf) r)
      mergedRules);
    countFor = rule: relation:
      requireOne "${rule.id} endpoint ${relation.direction} ${relation.role} count"
      (filter (r:
        r.id
        != rule.id
        && r.select == removeAttrs rule.select ["where"]
        && (r.check.kind or null) == "count"
        && r.check.relation == relation
        && r.check.compare == "eq"
        && r.check.value == 1)
      mergedRules);
    leafRequires = rule: leaf:
      if leaf.kind == "endpoint-path"
      then [(countFor rule leaf.upper) (countFor rule leaf.lower) (forestFor rule leaf)]
      else if leaf.kind == "visible-target"
      then [(forestFor rule leaf)]
      else [];
    rules = map (rule:
      rule
      // {
        requires = unique (concatLists (map (leafRequires rule)
          (leaves rule.check
            ++ (
              if rule.select ? where
              then leaves rule.select.where
              else []
            ))));
      })
    mergedRules;
    lowerNative = e:
      (removeAttrs e ["_kind" "constraints" "fields" "relations"])
      // {
        fields = map cleanField (e.fields or []);
        relations =
          if (e.relations or []) == []
          then null
          else map cleanRel e.relations;
      };
    # A native string field derives semantic type string. A choice or Boolean
    # field carries its own. No other native type has a semantic type in this
    # profile, so deriving one from the native tag would ship a bundle every
    # backend refuses.
    semanticOf = e: f: let
      native = head (attrNames (cleanField f));
    in
      f._semantic
      or (
        if native == "string"
        then {type = "string";}
        else throw "field ${(fieldBody f).title} on ${e.tag}: a ${native} field has no semantic type; declare it with str, choice, or boolean"
      );
    metadata = e: let
      schema = "semantic-types/v1";
      fields = map (f: {
        field = refId (fieldOf e f);
        native = cleanField f;
        semantic = semanticOf e f;
        default = f._default or null;
      }) (e.fields or []);
    in {
      inherit schema fields;
      grammar = root;
      element = elementId e.tag;
      digest = builtins.hashString "sha256" (builtins.toJSON {inherit schema fields;});
      defaultsApply = "surviving-new-record-final-absence-only";
    };
    lowerDecl = d: let
      config =
        lowerValue {
          inherit (d) name;
          id = declId d;
        }
        d.config;
      checkedConfig =
        if d._kind == "input"
        then
          config
          // {
            kind = keyword "input.config.kind" ["external-snapshot"] config.kind;
            required = keyword "input.config.required" [true] config.required;
            complete = keyword "input.config.complete" [true] config.complete;
          }
        else if d._kind == "projection"
        then
          config
          // {
            relationProjection = keyword "relationProjection" [["nativeType" "role" "target"]] config.relationProjection;
            existence = keyword "projection.existence" [true] config.existence;
            element = keyword "projection.element" [true] config.element;
            fieldPresence = keyword "projection.fieldPresence" [true] config.fieldPresence;
          }
        else config;
    in {
      id = declId d;
      kind = keyword "declaration.kind" ["view" "input" "projection"] d._kind;
      inherit (d) name;
      config = checkedConfig;
    };
    declarations =
      [
        {
          id = root;
          kind = "model";
          inherit (g) name;
        }
      ]
      ++ concatLists (map (e:
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
          direction = direction r;
          name = role r;
        }) (ownedRelations e)
        ++ map (f: {
          id = refId (fieldOf e f);
          kind = "field";
          owner = elementId e.tag;
          name = (fieldBody f).title;
        }) (e.fields or []))
      g.elements);
    output = {
      grammar = map lowerNative g.elements;
      semanticTypes = map metadata g.elements;
      bundle = {
        schema = "semantic-constraints/v2";
        id = root;
        inherit declarations rules;
        inherit views;
        inputs = map lowerDecl g.inputs;
        projections = map lowerDecl g.projections;
      };
    };
  in
    if length allIds != length (unique allIds)
    then throw "duplicate declaration identity"
    else builtins.deepSeq (validateKeywords output) output;
in {
  inherit el field rel model normalize check on all any not where parentOf childOf fieldOf count lt lte gt gte eq validateKeyword;
  contribute = name: subject: checks: {inherit name subject checks;};
  record = bind: sym "record" {inherit bind;};
  fieldIs = f: value: fieldValue f [value];
  fieldIn = fieldValue;
  ifPresent = term: sym "ifPresent" {inherit term;};
  at = node: term: sym "at" {inherit node term;};
  isNodeType = node: element: sym "isNodeType" {inherit node element;};
  atMost = n: c: lte (count c) n;
  atLeast = n: c: gte (count c) n;
  exactly = n: c: eq (count c) n;
  only = collection: let
    singleton = sym "only" {inherit collection;};
  in
    singleton // {target = sym "endpointTarget" {relation = singleton;};};
  allOf = all;
  const = value:
    if isBool value
    then
      (
        if value
        then all []
        else any []
      )
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
  isForest = view: sym "isForest" {inherit view;};
  visibility = name: hierarchy: policy:
    declaration "view" name {
      contract = "origin-sensitive-visibility/v1";
      inherit hierarchy policy;
    };
  visible = view: origin: target: sym "visible" {inherit view origin target;};
  canDescend = view: origin: target: sym "canDescend" {inherit view origin target;};
  nativeDag = sym "nativeDag" {};
  input = declaration "input";
  projection = declaration "projection";
  preserve = baseline: projection: sym "preserve" {inherit baseline projection;};
}

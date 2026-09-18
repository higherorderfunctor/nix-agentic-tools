# Gate 2 proposal. schema and constraint are new; only grammar.dsl exists today.
{
  grammar,
  schema,
  constraint,
}: let
  g = grammar.dsl;
  s = schema;
  c = constraint;
  uid = g.field.required (g.field.str "UID");
in
  s.grammar "reference" ({
    elements,
    views,
  }: {
    elements = {
      # Lesson: explicit bridge cardinalities and record path.
      BAR = _self: let
        endpoint = reverseRole: {
          inherit reverseRole;
          cardinality = c.exactly 1;
          constraints.targetType = rel: c.isNodeType rel.target elements.FOO;
        };
      in {
        fields = [uid];
        relations.P.parent = endpoint "P_back";
        relations.Q.child = endpoint "Q_back";
        constraints.endpointPath = bridge: let
          upper = c.only bridge.relations.P.parent;
          lower = c.only bridge.relations.Q.child;
        in
          views.visibility.canDescend upper.target lower.target;
      };
      # Lesson: another owner with the same role spelling.
      BAZ = _self: {
        fields = [uid];
        relations.Q.child.reverseRole = "Q_back";
        relations.R.parent.reverseRole = "R_back";
      };
      # Lesson: ordered typed fields and scoped relation predicates.
      FOO = self: {
        fields = [
          uid
          (s.field.boolean "FLAG" {
            required = true;
            default = s.default.literal false;
          })
        ];
        relations.H.parent = {
          reverseRole = "H_back";
          constraints.targetType = rel: c.isNodeType rel.target self;
        };
        relations.R.parent = {
          reverseRole = "R_back";
          constraints = {
            targetType = rel: c.isNodeType rel.target self;
            visibleTarget = rel: views.visibility.canSee rel.owner rel.target;
          };
        };
      };
    };
    # Lesson: selected forest and original-origin Boolean visibility.
    views = {
      H = c.forest {
        nodes = elements.FOO;
        edges = [elements.FOO.relations.H.parent];
      };
      visibility = c.boundaryVisibility {
        hierarchy = views.H;
        closed = node: c.fieldValue node elements.FOO.fields.FLAG;
      };
    };
    constraints = {
      # Mandatory complete graph check: every authored Parent/Child role/element.
      inherit (c) nativeDag;
      # Lesson: captured baseline plus an explicit projection.
      preserve = c.preserve {
        baseline = s.baseline "protected";
        projection = c.projection "authored-record/v1" {
          elementType = true;
          fieldsWhenPresent = [elements.FOO.fields.FLAG];
          ownedRelations = "set";
        };
      };
    };
  })

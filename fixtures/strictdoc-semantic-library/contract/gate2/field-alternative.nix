# Alternative representation. The custom contract is configured, not executed here.
{
  grammar,
  schema,
  constraint,
}: let
  g = grammar.dsl;
  s = schema;
  c = constraint;
  uid = g.field.required (g.field.str "UID");
  model = s.grammar "field-alternative" ({elements, ...}: {
    elements = {
      BAR = _self: {
        fields = [uid (g.field.required (g.field.str "UPPER")) (g.field.required (g.field.str "LOWER"))];
      };
      FOO = self: {
        fields = [uid (s.field.boolean "FLAG" {required = true;})];
        relations.H.parent = {
          reverseRole = "H_back";
          constraints.targetType = rel: c.isNodeType rel.target self;
        };
      };
    };
    views.H = c.forest {
      nodes = elements.FOO;
      edges = [elements.FOO.relations.H.parent];
    };
    constraints.nativeDag = c.nativeDag;
  });
  customRule = {
    id = "field-alternative/endpoint-path";
    scope = "model";
    contract = "consumer.field-adaptation/v1";
    config = {
      records = model.elements.BAR.ref;
      lower = model.elements.BAR.fields.LOWER.ref;
      upper = model.elements.BAR.fields.UPPER.ref;
      targetType = model.elements.FOO.ref;
      endpointValues = "exactly-one-nonempty-uid";
      resolution = "model-wide-uid";
      boundaryField = model.elements.FOO.fields.FLAG.ref;
      path = "downward-original-origin-boundary-visibility";
      virtualConnectivity = {
        shape = "upper-to-record-to-lower";
        cycleCheck = "union-with-all-native-parent-child";
        createAuthoredRelations = false;
      };
    };
    inputs = {
      candidate = {
        from = "candidate";
        schema = "sdoc-policy.model/v1";
      };
      hierarchy = {
        from = "view:field-alternative/view/H";
        schema = "sdoc-policy.forest/v1";
      };
    };
    needs = ["model.resolved-endpoints/v1" "semantic.boolean/v1" "virtual-union-dag/v1"];
    after = ["field-alternative/view/H/valid"];
  };
in {inherit customRule model;}

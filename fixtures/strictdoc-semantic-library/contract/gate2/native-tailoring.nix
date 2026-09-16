# Native adaptation/compliance statements need not impose a common hierarchy.
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
  s.grammar "tailoring" ({elements, ...}: {
    elements = {
      REQUIREMENT = _self: {fields = [uid];};
      STATEMENT = _self: let
        endpoint = reverseRole: {
          inherit reverseRole;
          cardinality = c.exactly 1;
          constraints.targetType = rel: c.isNodeType rel.target elements.REQUIREMENT;
        };
      in {
        fields = [uid];
        relations.P.parent = endpoint "P_back";
        relations.Q.child = endpoint "Q_back";
      };
    };
    constraints.nativeDag = c.nativeDag;
  })

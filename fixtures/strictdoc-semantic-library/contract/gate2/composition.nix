# Two equivalent alternate contributions; neither silently overrides the other.
{
  model,
  constraint,
}: let
  c = constraint;
  foo = model.elements.FOO;
  subject = foo.relations.R.parent;
  external = c.on subject {targetType = rel: c.isNodeType rel.target foo;};
  direct = {
    rules = [
      {
        id = "reference/element/FOO/relation/Parent/R/constraint/targetType";
        scope = "model";
        contract = "sdoc-policy.targets/v1";
        config = {
          select = {
            grammar = "reference";
            ownerElement = "FOO";
            nativeType = "Parent";
            role = "R";
          };
          allowed = [
            {
              grammar = "reference";
              element = "FOO";
            }
          ];
        };
        inputs.candidate = {
          from = "candidate";
          schema = "sdoc-policy.model/v1";
        };
        needs = ["model.resolved-endpoints/v1"];
        after = [];
      }
    ];
    views = [];
  };
in {
  inherit direct external;
  contributions = [
    {
      origin = "adjacent";
      bundle = model.normalized.bundle;
    }
    {
      origin = "external";
      bundle = external;
    }
    {
      origin = "direct";
      bundle = direct;
    }
  ];
}

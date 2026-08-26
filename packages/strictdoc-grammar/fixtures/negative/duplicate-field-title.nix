# Rejected at NIX EVALUATION, by this package's own duplicate-title assertion.
# StrictDoc has no rule for this anywhere: the .sgra parses, exports exit 0, and
# the by-name field lookup silently keeps the LAST declaration.
#
# Plain data against the NORMALIZED element shape -- deliberately not written
# through the DSL, so the fixture does not track the DSL's constructor names.
{
  tag = "NOTE";
  prefix = "NOTE-";
  fields = [
    {
      title = "UID";
      kind.string = {required = true;};
    }
    {
      title = "STATEMENT";
      kind.string = {required = true;};
    }
    {
      title = "STATEMENT";
      kind.singleChoice = {choices = ["alpha" "beta"];};
    }
  ];
  relations = [];
}

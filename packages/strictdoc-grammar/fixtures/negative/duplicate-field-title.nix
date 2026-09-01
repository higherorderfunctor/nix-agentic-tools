# Rejected at NIX EVALUATION, by this package's own duplicate-title assertion.
# StrictDoc has no rule for this anywhere: the .sgra parses, exports exit 0, and
# the by-name field lookup silently keeps the LAST declaration.
#
# Plain data against the NORMALIZED element shape -- deliberately not written
# through the DSL, so the fixture does not track the DSL's constructor names.
# `title` sits INSIDE the chosen alternative because each of the four
# GrammarElementField* rules carries its own TITLE production.
{
  tag = "NOTE";
  prefix = "NOTE-";
  fields = [
    {
      string = {
        title = "UID";
        required = true;
      };
    }
    {
      string = {
        title = "STATEMENT";
        required = true;
      };
    }
    {
      singleChoice = {
        title = "STATEMENT";
        required = false;
        choices = ["alpha" "beta"];
      };
    }
  ];
}

# Rejected at NIX EVALUATION, by this package's own duplicate-role assertion.
# StrictDoc has no rule for this anywhere: the .sgra parses, exports exit 0, and
# the by-role relation lookup silently keeps the FIRST declaration -- the
# opposite direction from the duplicate-field-title case, and equally silent.
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
  ];
  relations = [
    {
      parent = {
        role = "Refines";
        reverseRole = "Refined_By";
      };
    }
    {
      parent = {
        role = "Refines";
        reverseRole = "Something_Else";
      };
    }
  ];
}

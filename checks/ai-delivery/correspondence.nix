# A live observation, independent of the checked-in generated rows. Absence is
# checked in both directions; an empty file map is never its own justification.
{lib}: {
  absentKeys,
  policy,
}: let
  absentErrors = lib.concatMap (row: let
    observedAbsent = builtins.elem (policy.key row) absentKeys;
  in
    lib.optional (row.primitive
      != "ownWrapper"
      && (row.primitive == "notApplicable") != observedAbsent)
    ("${policy.key row}: "
      + (
        if row.primitive == "notApplicable"
        then "absent row has a live delivery entry"
        else "delivery layer has an absent surface without an absent row"
      )))
  policy.rows;
in
  absentErrors

# A live observation, independent of the checked-in generated rows. Absence is
# checked in both directions; an empty file map is never its own justification.
{lib}: {
  absentKeys,
  delegations,
  policy,
}: let
  absentErrors = lib.concatMap (row:
    lib.optional (row.primitive
      != "ownWrapper"
      && ((row.primitive == "notApplicable") != builtins.elem (policy.key row) absentKeys))
    ("${policy.key row}: "
      + (
        if row.primitive == "notApplicable"
        then "absent row has a live delivery entry"
        else "delivery layer has an absent surface without an absent row"
      )))
  policy.rows;
  upstreamErrors = lib.concatMap (row:
    lib.optional (row.primitive
      == "upstream"
      && !(lib.any (entry:
        policy.key entry == policy.key row && entry.writerAttr == row.writerAttr)
      delegations))
    "${policy.key row}: upstream row has no corresponding delivery sink ${lib.showOption row.writerAttr}")
  (lib.concatMap policy.writersOf policy.rows);
in
  absentErrors ++ upstreamErrors

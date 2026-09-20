# A live observation, independent of the checked-in generated rows. Absence is
# checked in both directions; an empty file map is never its own justification.
{lib}: {
  absentKeys,
  delegations,
  policy,
}: let
  # An `offLayer` row describes a file a factory still lowers itself, outside
  # the layer this observation reads. It must stay invisible to the layer: the
  # day the factory moves the file onto `ai.<runtime>.files`, the row is stale
  # and this names it for deletion, so the escape retires itself.
  absentErrors = lib.concatMap (row: let
    observedAbsent = builtins.elem (policy.key row) absentKeys;
  in
    lib.optional (row.primitive
      != "ownWrapper"
      && (
        if row ? offLayer
        then !observedAbsent
        else (row.primitive == "notApplicable") != observedAbsent
      ))
    ("${policy.key row}: "
      + (
        if row ? offLayer
        then "offLayer row now has a live delivery entry; delete it from config/ai-delivery-facts.nix and regenerate"
        else if row.primitive == "notApplicable"
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

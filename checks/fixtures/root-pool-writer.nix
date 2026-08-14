# POSITIVE CONTROL for the root-pool provenance guard in ../module-eval.nix.
#
# A module in a FILE that writes a ROOT `ai.*` option. The guard's steady state
# is zero violations, so without this a broken guard — a bad prefix comparison,
# an option filter that selects nothing, a `definitionsWithLocations` that
# stopped carrying files — would be INDISTINGUISHABLE from a clean tree and
# would report success forever.
#
# The write deliberately uses the two shapes that defeated the regex scan this
# guard replaced, so the fixture also pins WHY the pivot happened:
#
#   - the `config.` prefix, which the scan's `(^|[^.\w-])` anchor excluded
#     because it could not tell a read from a write; and
#   - `lib.genAttrs`, dynamic construction, which is UNDECIDABLE in a regex.
#
# Provenance sees through both, because it runs after evaluation: by then there
# is no syntax left, only definitions and the files they came from.
#
# This is the ONE place a root pool may be written from a repo file without
# being a defect, and it is safe because nothing imports it except that test.
{lib, ...}: {
  config.ai.skills = lib.genAttrs ["provenance-positive-control"] (_: ./.);
}

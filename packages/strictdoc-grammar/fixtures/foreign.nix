# The DSL values for ./foreign.sgra — acceptance item 7, the round-trip of a
# deliberately FOREIGN grammar. Nothing here is specific to this repository;
# that is the point. It reaches the half of StrictDoc's surface the five node
# types in ../values.nix never touch:
#
#   composite element, VIEW_STYLE, field HUMAN_TITLE, Tag field,
#   MultipleChoice field, Child relation, File relation carrying a ROLE,
#   role-less Parent relation, element with NO PREFIX and no PROPERTIES block
#   at all, and a quoted choice option containing parentheses.
#
# Two of those need the generic constructors rather than the named ones, which
# is exactly what the generic constructors are for: `rel.mk "file"` because
# `rel.file` is the bare role-less value, and `rel.mk "parent" {}` because
# `rel.parent` takes both roles positionally. `field.raw` carries HUMAN_TITLE,
# which no named constructor takes — and `raw` escapes the CONSTRUCTORS, never
# the surface: the value still has to type-check.
{dsl}: let
  inherit (dsl) el field rel;
  inherit (field) many one raw required str tag;
in [
  (el "CHAPTER" {
      isComposite = true;
      prefix = "CH-";
      viewStyle = "Narrative";
    } {
      fields = [
        (required (str "UID"))
        (required (raw {
          string = {
            title = "TITLE";
            humanTitle = "Chapter heading";
          };
        }))
        (tag "LABELS")
        (many "AUDIENCE" ["reader" "author" "reviewer"])
      ];
      relations = [
        (rel.child "Contains" "Contained_By")
        (rel.mk "file" {role = "Renders_From";})
      ];
    })

  (el "NOTE" {} {
    fields = [
      (required (str "UID"))
      (required (str "STATEMENT"))
      (one "LICENCE" ["MIT (Expat)" "GPL-3.0-or-later" "proprietary"])
      (str "NOTES")
    ];
    relations = [
      (rel.parent "Refines" "Refined_By")
      (rel.mk "parent" {})
      rel.file
    ];
  })
]

# A relation key that is neither parent, child nor file reaches the direction
# keyword space, which names it. Dropping it would hide the typo.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field rel model normalize;
  inherit (field) required str;

  uid = required (str "UID");

  note = el "NOTE" {} {
    fields = [uid];
    relations = [(rel.mk "sibling" {role = "S";})];
  };
in
  normalize (model "guard" {elements = [note];})

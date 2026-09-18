# The native single-choice constructor is reachable through this stub's field
# set, and it carries no semantic type. Authoring it with choice does.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field model normalize;
  inherit (field) required str;

  uid = required (str "UID");

  note = el "NOTE" {} {fields = [uid (field.one "STATE" ["draft" "final"])];};
in
  normalize (model "guard" {elements = [note];})

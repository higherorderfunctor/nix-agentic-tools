# The owner of an H occurrence is a NOTE, and NOTE declares no STATE. The
# occurrences selector fixes that owner, so the field resolves at lowering.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field rel model normalize fieldIs at;
  inherit (field) required str choice;
  inherit (rel) parent;

  uid = required (str "UID");
  taskState = choice "STATE" ["open" "closed"];

  note = el "NOTE" {} {
    fields = [uid];
    relations = [(parent "H" "H_back" (edge: at edge.origin (fieldIs taskState "open")))];
  };
  task = el "TASK" {} {fields = [uid taskState];};
in
  normalize (model "guard" {elements = [note task];})

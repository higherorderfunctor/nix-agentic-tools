# The accepted counterpart of the owner probe. A target subject fixes no
# element, so TASK's STATE resolves against the model and blocks at evaluation
# on a target that does not declare it.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field rel model normalize fieldIs at;
  inherit (field) required str choice;
  inherit (rel) parent;

  uid = required (str "UID");
  taskState = choice "STATE" ["open" "closed"];

  note = el "NOTE" {} {
    fields = [uid];
    relations = [(parent "H" "H_back" (edge: at edge.target (fieldIs taskState "open")))];
  };
  task = el "TASK" {} {fields = [uid taskState];};
in
  normalize (model "guard" {elements = [note task];})

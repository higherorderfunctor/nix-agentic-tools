# Two elements declare STATE with different choices. The NOTE check is handed
# TASK's constructor, so its value is a TASK state on a NOTE record.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field model normalize check record fieldIs;
  inherit (field) required str choice;

  uid = required (str "UID");
  noteState = choice "STATE" ["draft" "final"];
  taskState = choice "STATE" ["open" "closed"];

  note = el "NOTE" {} {
    fields = [uid noteState];
    constraints = [
      (check "notes-are-open" (record (_node: fieldIs taskState "open")))
    ];
  };
  task = el "TASK" {} {fields = [uid taskState];};
in
  normalize (model "guard" {elements = [note task];})

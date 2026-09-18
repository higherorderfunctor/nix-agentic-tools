# A note cites the source it replaces. One choice field carries its state.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field rel model normalize check record any not on where;
  inherit (field) required str choice;
  inherit (rel) parent;
  inherit (dsl) atLeast exactly fieldIs fieldIn ifPresent at;

  uid = required (str "UID");
  state = choice "STATE" ["draft" "final" "retired"];

  note = el "NOTE" {} {
    fields = [uid state];
    relations = [
      (parent "SOURCE" "SOURCE_back" (edge: at edge.target (ifPresent (fieldIn state ["final" "retired"]))))
    ];
    constraints = [
      (on (where note (fieldIs state "retired"))
        (check "retired-notes-cite-a-source" (record (node: atLeast 1 (node.parents "SOURCE")))))
      (check "drafts-cite-nothing" (record (node:
        any [
          (not (fieldIs state "draft"))
          (exactly 0 (node.parents "SOURCE"))
        ])))
    ];
  };
in
  normalize (model "notes" {elements = [note];})

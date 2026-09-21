# A File relation names a path, so it declares no owned occurrence. It reaches
# the native grammar and no semantic declaration.
let
  dsl = import ../../../dsl.nix;
  inherit (dsl) el field rel model normalize;
  inherit (field) required str;
  inherit (rel) parent;

  uid = required (str "UID");

  note = el "NOTE" {} {
    fields = [uid];
    relations = [(parent "H" "H_back") rel.file];
  };
in
  normalize (model "guard" {elements = [note];})

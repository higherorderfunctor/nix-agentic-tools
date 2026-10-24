{lib, ...} @ null: {
  _file = lib.id "shadowed-at-null.nix";
  demo.answer = null;
}

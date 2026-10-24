true @ {lib, ...}: {
  _file = lib.id "shadowed-at-bool.nix";
  demo.answer = true;
}

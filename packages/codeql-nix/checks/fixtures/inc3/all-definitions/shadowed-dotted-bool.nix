let
  true.foo = "shadowed";
in {
  _file = "shadowed-dotted-bool.nix";
  demo.answer = true;
}

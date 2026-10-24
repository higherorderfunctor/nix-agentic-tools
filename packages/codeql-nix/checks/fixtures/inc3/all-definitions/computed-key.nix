_: let
  name = "answer";
in {
  _file = "computed-key.nix";
  demo.${name} = 1;
}

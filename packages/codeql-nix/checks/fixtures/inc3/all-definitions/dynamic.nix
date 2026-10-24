{lib, ...}: {
  _file = "dynamic.nix";
  demo.answer = lib.mkIf (builtins.add 0 1 == 2) 3;
}

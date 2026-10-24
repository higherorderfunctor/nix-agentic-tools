{lib, ...}: {
  _file = "ambiguous.nix";
  demo.answer = lib.mkMerge [1 2];
}

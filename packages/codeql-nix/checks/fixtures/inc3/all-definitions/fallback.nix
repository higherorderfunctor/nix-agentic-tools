{lib, ...}: {
  _file = "fallback.nix";
  demo.answer = lib.mkDefault 2;
}

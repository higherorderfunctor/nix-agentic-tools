{lib, ...}: {
  _file = "fallback.nix";
  demo.answer = lib.mkOverride 50 2;
}

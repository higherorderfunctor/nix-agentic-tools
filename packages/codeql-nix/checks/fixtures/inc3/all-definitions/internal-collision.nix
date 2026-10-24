{lib, ...}: {
  _file = "internal-collision.nix";
  key = "@@NIXQL_INTERNAL_MODULE_KEY@@";
  demo.answer = lib.mkDefault 3;
}

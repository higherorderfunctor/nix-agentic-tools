{lib, ...}: {
  _file = "override-over-if.nix";
  demo.answer = lib.mkOverride 10 (lib.mkIf false 1);
}

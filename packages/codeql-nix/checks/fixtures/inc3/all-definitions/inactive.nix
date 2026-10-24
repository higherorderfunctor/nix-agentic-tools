{lib, ...}: {
  _file = "inactive.nix";
  demo.answer = lib.mkIf false (lib.mkOverride 10 (throw "M3d inactive"));
}

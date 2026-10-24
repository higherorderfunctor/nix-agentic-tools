{lib, ...}: {
  config = lib.mkIf false (throw "M3d opaque body");
}

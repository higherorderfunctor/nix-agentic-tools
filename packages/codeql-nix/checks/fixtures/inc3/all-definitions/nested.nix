{lib, ...}: {
  _file = "nested.nix";
  demo.answer = lib.mkIf true (lib.mkMerge [
    (lib.mkOrder 700 ["left"])
    (lib.mkIf false (lib.mkAfter ["right"]))
  ]);
}

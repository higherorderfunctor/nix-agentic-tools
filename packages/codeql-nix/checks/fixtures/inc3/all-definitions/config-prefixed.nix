{lib, ...}: {
  _file = "config-prefixed.nix";
  config.demo.answer = lib.mkForce 7;
}

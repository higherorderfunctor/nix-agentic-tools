{lib, ...}: {
  _file = "disabled.nix";
  key = "disabled";
  disabledModules = [{key = "disabled";}];
  demo.answer = lib.mkOverride 20 20;
}

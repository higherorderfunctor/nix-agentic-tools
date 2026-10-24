{lib, ...}: {
  _file = "real-custom-property.nix";
  demo.answer = lib.mkDefinition {
    file = "definition-origin";
    value = 1;
  };
}

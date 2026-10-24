{lib, ...}: {
  _file = "with-expression.nix";
  demo.answer = with lib; mkIf false 1;
}

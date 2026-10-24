{lib, ...}: {
  _file = "if-expression.nix";
  demo.answer =
    if true
    then lib.mkForce 1
    else 2;
}

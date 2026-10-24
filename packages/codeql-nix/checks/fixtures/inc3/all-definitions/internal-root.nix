{...}: {
  _file = "internal-root.nix";
  imports = [./internal-collision.nix];
  demo.answer = 1;
}

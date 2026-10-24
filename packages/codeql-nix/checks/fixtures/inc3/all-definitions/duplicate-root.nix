{...}: {
  _file = "duplicate-root.nix";
  imports = [./duplicate-first.nix ./duplicate-second.nix];
}

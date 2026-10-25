{pkgs, ...}: {
  imports = [./fragment-routing.nix ./instructions-drift.nix ./isolate-prek-hooks.nix];
  _module.args.isolator = import ../../lib/isolate-prek-hooks.nix {inherit pkgs;};
}

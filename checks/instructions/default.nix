{
  instr,
  pkgs,
  ...
}: {
  imports = [./instruction-materialization.nix ./instruction-ownership.nix ./instructions-drift.nix ./isolate-prek-hooks.nix];
  _module.args = {
    isolator = import ../../lib/isolate-prek-hooks.nix {inherit pkgs;};
    materializer = import ../../lib/materialize-repo-instructions.nix {inherit instr pkgs;};
  };
}

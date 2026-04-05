_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
  common = import ./common.nix {inherit fragmentsLib;};
in {
  agentic-fragments = {
    inherit common;
    inherit (fragmentsLib) compose mkFragment;
  };
}

{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  gate = import ./gate.nix {inherit lib;} {
    inherit policy;
    evaluators = {
      devenv = config: (harness.evalDevenv config).config;
      hm = config: (harness.evalHm config).config;
    };
  };
  fixtures = import ./fixtures.nix {inherit lib;};
in {
  checks = {
    ai-delivery = assert gate.passed;
      pkgs.runCommandLocal "ai-delivery-check" {} ''
        echo 'PASS: ${toString (builtins.length policy.rows)} delivery rows; ${toString gate.checked} imperative writers survive populated and empty declarations' > "$out"
      '';
    ai-delivery-fixtures = assert fixtures.passed;
      pkgs.runCommandLocal "ai-delivery-fixtures-check" {} ''
        echo ${lib.escapeShellArg (lib.concatStringsSep "\n" fixtures.broken.errors)}
        echo 'PASS: unconditional control accepted; gated writer and invalid policy fixtures rejected' > "$out"
      '';
  };
}

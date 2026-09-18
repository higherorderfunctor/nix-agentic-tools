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
  imports = [./materializer-runtime.nix];

  checks = {
    ai-delivery = assert gate.passed;
      pkgs.runCommandLocal "ai-delivery-check" {} ''
        echo 'PASS: ${toString (builtins.length policy.rows)} delivery rows; ${toString gate.checked} imperative writers survive populated and empty declarations and differ between them' > "$out"
      '';
    ai-delivery-fixtures = assert fixtures.passed;
      pkgs.runCommandLocal "ai-delivery-fixtures-check" {} ''
        echo ${lib.escapeShellArg (lib.concatStringsSep "\n" fixtures.broken.errors)}
        echo 'PASS: unconditional control and recorded exemption accepted; gated writer, stale exemption, and invalid policy fixtures rejected' > "$out"
      '';
  };
}

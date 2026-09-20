{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  observation = import ./generate.nix {inherit harness lib pkgs;};
  gate = import ./gate.nix {inherit lib;} {
    inherit policy;
    correspondenceErrors =
      observation.assertionErrors
      ++ (import ./correspondence.nix {inherit lib;} {
        inherit policy;
        inherit (observation) absentKeys delegations;
      });
    evaluators = {
      devenv = config: (harness.evalDevenv config).config;
      hm = config: (harness.evalHm config).config;
    };
  };
  fixtures = import ./fixtures.nix {inherit lib pkgs;};
in {
  checks = {
    ai-delivery = assert gate.passed;
      pkgs.runCommandLocal "ai-delivery-check" {} ''
        echo 'PASS: ${toString (builtins.length policy.rows)} delivery rows; ${toString gate.checked} imperative writers survive populated and empty declarations and differ between them' > "$out"
      '';
    ai-delivery-fixtures = assert fixtures.passed;
      pkgs.runCommandLocal "ai-delivery-fixtures-check" {} ''
        echo ${lib.escapeShellArg (lib.concatStringsSep "\n" fixtures.broken.errors)}
        echo 'PASS: real delivery writers and recorded exemptions accepted; broken writers, stale claims, malformed bodies and policy schemas rejected' > "$out"
      '';
    ai-delivery-generated =
      pkgs.runCommandLocal "ai-delivery-generated-check" {
        passthru = {inherit (observation) generated;};
      } ''
        echo 'Checking the committed delivery matrix against the live delivery layer'
        diff -u ${../../config/ai-delivery-generated.nix} ${observation.generated}
        echo 'PASS: generated delivery matrix is byte-identical' > "$out"
      '';
  };
}

# The vendor workflow-steering extractor behind
# ai.kiro.workflowReminder.includeVendorSteering.
{pkgs, ...}: {
  checks = {
    kiro-workflows-steering-fixtures = pkgs.runCommandLocal "kiro-workflows-steering-fixtures-check" {} ''
      ${pkgs.python3}/bin/python3 ${./kiro-workflows-steering-fixtures.py} ${../lib/kiro-workflows-steering.py}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}

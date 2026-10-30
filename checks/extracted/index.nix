{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) index load;
  owners = import ./owners.nix;
  checkNames = builtins.filter (lib.hasSuffix "-extracted") (builtins.attrNames self.checks.${pkgs.stdenv.hostPlatform.system});
  factDirectories = map (name: ../../packages + "/${name}/extracted") (builtins.filter
    (name: builtins.pathExists (../../packages + "/${name}/extracted/facts.json"))
    (builtins.attrNames (builtins.readDir ../../packages)));
  # Refuse a packages/<owner>/extracted/ directory with facts.json, or an
  # <owner>-extracted check, absent from the PR CI planner's owners.nix map.
  unregistered = registered:
    map toString (builtins.filter (dir: !(lib.elem dir (builtins.attrValues registered))) factDirectories)
    ++ builtins.filter (name: !(builtins.hasAttr (lib.removeSuffix "-extracted" name) registered)) checkNames;
in {
  checks.extracted-index = index (lib.mapAttrs (_: dir: load {inherit dir;}) owners);
  checks.extracted-owner-registration = assert lib.assertMsg (unregistered owners == [])
  "extracted-owner-registration: register in checks/extracted/owners.nix: ${lib.concatStringsSep ", " (unregistered owners)}";
  # Removing Codex must name both its committed facts directory and check.
  assert lib.assertMsg
  (unregistered (builtins.removeAttrs owners ["chatgpt-codex"]) == [(toString owners.chatgpt-codex) "chatgpt-codex-extracted"])
  "extracted-owner-registration: removing chatgpt-codex did not refuse its facts directory and check";
    pkgs.writeText "extracted-owner-registration" "All committed facts directories and owner extraction checks are registered.\n";
}

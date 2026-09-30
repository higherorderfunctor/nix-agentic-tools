# `git.absorb.{enable,settings}`, declared once for both backends. The typed
# settings are generated from git-absorb's drift-checked sidecar
# (packages/git-absorb/extracted.json) by lib/git-tool-settings; the shared factory
# lowers them into `git.settings` (packages/git), which each backend
# delivers.
{
  backend,
  lib,
}:
import ../../../lib/git-tool-settings/tool-module.nix {
  inherit backend;
  package = pkgs: pkgs.ai.gitTools.git-absorb;
  section = "absorb";
  settings = (import ../lib/default.nix).git-absorb.settings {inherit lib;};
  tool = "git-absorb";
}

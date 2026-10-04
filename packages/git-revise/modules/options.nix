# `git.revise.{enable,settings}`, declared once for both backends. The typed
# settings are generated from git-revise's drift-checked sidecar
# (packages/git-revise/extracted.json) by lib/git-tool-settings; the shared factory
# lowers them into `git.settings` (packages/git), which each backend
# delivers.
{
  backend,
  lib,
}:
import ../../../lib/git-tool-settings/tool-module.nix {
  inherit backend;
  package = ai: ai.gitTools.git-revise;
  section = "revise";
  settings = (import ../lib/default.nix).git-revise.settings {inherit lib;};
  tool = "git-revise";
}

# glab devenv module — project-local scope.
#
# Option DECLARATIONS live in ../options.nix, shared with the
# home-manager facet so the two cannot drift. This file is only the
# devenv-side wiring: default the package out of the overlay and put the
# wrapped glab in the project's dev shell.
#
# The wrapper reads its secrets at invocation time, so a project-local
# glab picks up a rotated sops file with no shell re-entry — the same
# behavior the HM facet gets.
#
# The facets deliberately differ in two lifecycle details. `configDir` defaults
# to a `glab-cli` directory under the project's devenv state —
# resolved from `config.devenv.state` at EVAL time, NOT the literal string
# `$DEVENV_STATE`, which the wrapper shell-quotes and would never expand.
# A project-local glab therefore keeps its own `hosts:`, aliases and
# update bookkeeping there instead of mutating `~/.config/glab-cli`. Two
# projects pointed at different GitLab instances then cannot fight over
# one config file, and the state is disposable with the rest of
# `.devenv/`. The HM facet leaves it `null` on purpose: a user-global install
# SHOULD be the thing that owns `~/.config/glab-cli`. `keyringSync` is declared
# for option parity but rejected here: a repository shell may consume global
# auth, but it must not own graphical-session login services.
#
# This is a default in `config`, not a different option DECLARATION — the
# option tree stays identical to the HM facet's, which is what
# `module-glab-hm-devenv-option-parity` asserts.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.glab;
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.keyringSync.enable;
          message = "glab.keyringSync.enable is Home Manager-only: devenv may consume a user's existing keyring, but a repository shell must not own login or graphical-session services.";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      glab.package = lib.mkDefault pkgs.ai.devTools.glab;
      # A real eval-time path, not a `$DEVENV_STATE` string: `devenv eval
      # devenv.state` resolves to an absolute path, so nothing has to expand
      # at invocation time.
      glab.configDir = lib.mkDefault "${config.devenv.state}/glab-cli";

      packages = [
        (import ../../lib/mkGlab.nix {inherit lib pkgs cfg;})
      ];
    })
    (lib.mkIf (cfg.enable && lib.hasAttrByPath ["ai" "codex" "internal"] options && config.ai.codex.enable) {
      ai.codex.internal._integration_writable_roots = lib.mkAfter [cfg.configDir];
    })
  ];
}

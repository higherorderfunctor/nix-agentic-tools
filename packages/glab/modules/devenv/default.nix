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
# The ONE place the facets deliberately differ is `configDir`. Here it
# defaults to a `glab-cli` directory under the project's devenv state —
# resolved from `config.devenv.state` at EVAL time, NOT the literal string
# `$DEVENV_STATE`, which the wrapper shell-quotes and would never expand.
# A project-local glab therefore keeps its own `hosts:`, aliases and
# update bookkeeping there instead of mutating `~/.config/glab-cli`. Two
# projects pointed at different GitLab instances then cannot fight over
# one config file, and the state is disposable with the rest of
# `.devenv/`. The HM facet leaves it `null` on purpose: a user-global
# install SHOULD be the thing that owns `~/.config/glab-cli`.
#
# This is a default in `config`, not a different option DECLARATION — the
# option tree stays identical to the HM facet's, which is what
# `module-glab-hm-devenv-option-parity` asserts.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.glab;
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkIf cfg.enable {
    glab.package = lib.mkDefault pkgs.generic.glab;
    # A real eval-time path, not a `$DEVENV_STATE` string: `devenv eval
    # devenv.state` resolves to an absolute path, so nothing has to expand
    # at invocation time.
    glab.configDir = lib.mkDefault "${config.devenv.state}/glab-cli";

    packages = [
      (import ../../lib/mkGlab.nix {inherit lib pkgs cfg;})
    ];
  };
}

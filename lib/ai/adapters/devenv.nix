# The devenv adapter: the router's result as devenv config.
#
# It is the only code in the delivery layer allowed to write `files` and
# `tasks`, and it knows nothing about any runtime.
{
  lib,
  pkgs,
}: let
  deliver = import ../deliver.nix {inherit lib pkgs;};
in
  args: let
    delivery = deliver (args // {backend = "devenv";});
  in {
    inherit (delivery) assertions;
    # See adapters/hm.nix: the plan is the only eval-visible record of what a
    # writer will do.
    ai.${args.runtime}._ownPlans = delivery.owned.plans;
    # A failed writer only warns at shell entry, so every bundle also
    # contributes a verification that makes `devenv test` and CI fail.
    #
    # `mkIf` rather than an empty string: `enterTest` is a lines option, so an
    # empty definition still contributes a separator and would change the
    # bytes of a script this layer did not write. The condition is a VALUE, so
    # it is forced when the option merges rather than while the module system
    # is collecting definitions.
    enterTest = lib.mkIf (delivery.owned.enterTest != "") delivery.owned.enterTest;
    files = delivery.symlinkEntries;
    # ONE literal attribute path; see the note in adapters/hm.nix for why a
    # fragment per writer recurses.
    tasks =
      delivery.owned.tasks
      // lib.mapAttrs' (
        _name: writer:
          lib.nameValuePair (delivery.nameFor writer.entry) {
            after = delivery.afterEdges writer;
            # The `devenv:files` edge is added beside the `shell` token rather
            # than instead of it: `devenv:enterShell` is what unconditionally
            # guarantees the body runs before the shell, and `devenv:files`
            # exists only when the project declares files at all.
            before =
              delivery.beforeEdges writer
              ++ lib.optional (delivery.hasFiles && builtins.elem "shell" writer.before) "devenv:files";
            exec = delivery.commandBody writer;
          }
      )
      delivery.commands;
  }

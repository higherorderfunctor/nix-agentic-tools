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
  args @ {options, ...}: let
    delivery = deliver (args // {backend = "devenv";});
    # ONE literal attribute path; see the note in adapters/hm.nix for why a
    # fragment per writer recurses.
    tasks =
      delivery.owned.tasks
      // delivery.commandEntries (writer: {
        after = delivery.afterEdges writer;
        # The `devenv:files` edge is added beside the `shell` token rather
        # than instead of it: `devenv:enterShell` is what unconditionally
        # guarantees the body runs before the shell, and `devenv:files`
        # exists only when the project declares files at all.
        before =
          delivery.beforeEdges writer
          ++ lib.optional (delivery.hasFiles && builtins.elem "shell" writer.before) "devenv:files";
        exec = delivery.commandBody writer;
      });
  in
    lib.mkMerge (
      # See adapters/hm.nix: an upstream sink lands under a root this adapter
      # states as a literal, never one derived from a configuration value.
      map (root: lib.optionalAttrs (options ? ${root}) {${root} = delivery.upstreamUnder root;}) delivery.upstreamRoots
      ++ [
        {
          inherit (delivery) assertions;
          # See adapters/hm.nix: the plan is the only eval-visible record of what a
          # writer will do.
          ai.${args.runtime}._ownPlans = delivery.owned.plans;
          files = delivery.symlinkEntries;
        }
        # A failed writer only warns at shell entry, so every bundle also
        # contributes a verification that makes `devenv test` and CI fail.
        #
        # `mkIf` rather than an empty string: `enterTest` is a lines option, so
        # an empty definition still contributes a separator and would change
        # the bytes of a script this layer did not write. The condition is a
        # VALUE, so it is forced when the option merges rather than while the
        # module system is collecting definitions.
        #
        # `tasks` and `enterTest` are DEFINED only where the backend declares
        # them. A minimal harness that drives a factory declares neither, and
        # a definition of an undeclared option is an error whatever its value —
        # which is why the harness had to grow a stub for options it has no use
        # for. The condition reads the OPTION tree, never config, so it settles
        # before any definition is collected: the same seam `warnings` uses in
        # mkBackendTransform.nix. Anything that WOULD have been dropped is said
        # out loud rather than quietly not written.
        (lib.optionalAttrs (options ? tasks) {inherit tasks;})
        (lib.optionalAttrs (options ? enterTest) {
          enterTest = lib.mkIf (delivery.owned.enterTest != "") delivery.owned.enterTest;
        })
        {
          assertions = lib.optional (!(options ? tasks) && tasks != {}) {
            assertion = false;
            message = ''
              ai.${args.runtime} declares writers that lower to devenv tasks
              (${lib.concatStringsSep ", " (lib.attrNames tasks)}), but this
              evaluation declares no `tasks` option for them to land in.
            '';
          };
        }
      ]
    )

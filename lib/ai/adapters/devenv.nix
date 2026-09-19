# The devenv adapter: the router's result as devenv config.
#
# It is the only code in the delivery layer allowed to write `files` and
# `tasks`, and it knows nothing about any runtime.
{lib}: let
  deliver = import ../deliver.nix {inherit lib;};
in
  args: let
    delivery = deliver (args // {backend = "devenv";});
  in {
    # ONE literal attribute path; see the note in adapters/hm.nix for why a
    # fragment per writer recurses.
    tasks =
      lib.mapAttrs' (
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

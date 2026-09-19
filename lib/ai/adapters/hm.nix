# The Home Manager adapter: the router's result as home-manager config.
#
# It is the only code in the delivery layer allowed to write `home.file` and
# `home.activation`, and it knows nothing about any runtime.
{lib}: let
  deliver = import ../deliver.nix {inherit lib;};
in
  args: let
    delivery = deliver (args // {backend = "hm";});
  in {
    # ONE literal attribute path, carrying a value derived from the writer set
    # — never one fragment per writer. The module system walks a fragment's KEY
    # structure while it is still collecting definitions, so a fragment whose
    # keys come out of `ai.<runtime>.activation` forces that option in the
    # middle of collecting the definitions it is made of, and evaluation dies
    # with an infinite recursion naming `_module.freeformType`. Measured on
    # this file. Keys derived from an option belong inside a VALUE.
    home.activation =
      lib.mapAttrs' (
        _name: writer:
          lib.nameValuePair (delivery.nameFor writer.entry) (
            # `entryBetween` rather than `entryAfter`: a body that deletes a
            # real file has to run BEFORE `checkLinkTargets`, and one that
            # writes a new file after `linkGeneration`, so both ends of the
            # position are the writer's to state.
            lib.hm.dag.entryBetween
            (delivery.beforeEdges writer)
            (delivery.afterEdges writer)
            (delivery.commandBody writer)
          )
      )
      delivery.commands;
  }

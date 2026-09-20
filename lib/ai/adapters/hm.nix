# The Home Manager adapter: the router's result as home-manager config.
#
# It is the only code in the delivery layer allowed to write `home.file` and
# `home.activation`, and it knows nothing about any runtime.
{
  lib,
  pkgs,
}: let
  deliver = import ../deliver.nix {inherit lib pkgs;};
in
  args @ {options, ...}: let
    delivery = deliver (args // {backend = "hm";});
  in
    lib.mkMerge (
      # An upstream sink lands under a root this adapter states as a LITERAL,
      # and only under one the backend actually declares. See the
      # `upstreamRoots` table in ../deliver.nix for the measured reason a
      # derived attribute name cannot be used here.
      map (root: lib.optionalAttrs (options ? ${root}) {${root} = delivery.upstreamUnder root;}) delivery.upstreamRoots
      ++ [
        {
          inherit (delivery) assertions;
          # Every writer's reconciliation plan, as data a module-eval check can read:
          # the emitted body names neither the document it reconciles nor the bytes
          # it writes, and the plan file itself cannot be read back at evaluation.
          ai.${args.runtime}._ownPlans = delivery.owned.plans;
          # Home Manager recurses a directory source natively, so a symlinked entry
          # lowers one-to-one.
          home.file = delivery.symlinkEntries;
          # ONE literal attribute path, carrying a value derived from the writer set
          # — never one fragment per writer. The module system walks a fragment's KEY
          # structure while it is still collecting definitions, so a fragment whose
          # keys come out of `ai.<runtime>.activation` forces that option in the
          # middle of collecting the definitions it is made of, and evaluation dies
          # with an infinite recursion naming `_module.freeformType`. Measured on
          # this file. Keys derived from an option belong inside a VALUE.
          home.activation =
            delivery.owned.activation
            // delivery.commandEntries (writer:
              # `entryBetween` rather than `entryAfter`: a body that deletes a
              # real file has to run BEFORE `checkLinkTargets`, and one that
              # writes a new file after `linkGeneration`, so both ends of the
              # position are the writer's to state.
                lib.hm.dag.entryBetween
                (delivery.beforeEdges writer)
                (delivery.afterEdges writer)
                (delivery.commandBody writer));
        }
      ]
    )

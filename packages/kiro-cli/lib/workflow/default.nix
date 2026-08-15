# Typed Kiro workflow definitions — barrel.
#
# Three layers, deliberately separable:
#
#   types.nix    what one node can prove about itself (option types)
#   analyze.nix  what only the whole tree can prove (counts, ids, orientation,
#                cross-node template references), plus policy lints
#   render.nix   authored shape -> engine wire JSON
#
# Authoring runs ONE WAY. Nix is a GENERATOR for this format and never a
# consumer of it: an authored attrset goes in, wire JSON comes out, and there
# is no public wire reader. `./parse.nix` does read wire JSON, but it is
# TEST-ONLY SCAFFOLDING and is deliberately absent from this barrel — it
# exists so the vendor check can load the seven recipes shipped inside the
# engine bundle and show these option types can express them.
# `checks/kiro-workflow-schema.nix` imports it by path.
#
# The format is undocumented upstream — it appears in zero public Kiro docs —
# so every rule traces to a read of the shipped KAS bundle. Constants live in
# ./engine-limits.json and are shared with the Effect-TS port under
# packages/kiro-cli/schema/, which is the same contract in the other language.
#
# Typical use, validating and rendering in one step:
#
#   wf = (lib.evalModules {
#     modules = [
#       {options.workflow = lib.mkOption {type = kiroWorkflow.types.workflowType;};}
#       {workflow = { name = "review"; steps = [ {step = {...};} ]; };}
#     ];
#   }).config.workflow;
#   json = kiroWorkflow.render.toJSONAs "review" (kiroWorkflow.analyze.assertValid {} wf);
#
# Deliver the result by COPYING it into <workspace>/.kiro/workflows/. Do not
# symlink it from the store — see the hazard note in render.nix.
{lib}: let
  types = import ./types.nix {inherit lib;};
  analyze = import ./analyze.nix {inherit lib;};
  render = import ./render.nix {inherit lib;};
in {
  inherit analyze render types;

  # Engine constants, for consumers that need to reason about the caps
  # (e.g. sizing a fan-out against the 20-step ceiling) without importing
  # the option types.
  inherit (types) engine;
}

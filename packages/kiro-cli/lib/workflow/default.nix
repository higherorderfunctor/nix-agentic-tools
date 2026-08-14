# Typed Kiro workflow definitions — barrel.
#
# Three layers, deliberately separable:
#
#   types.nix    what one node can prove about itself (option types)
#   analyze.nix  what only the whole tree can prove (counts, ids, orientation,
#                cross-node template references), plus policy lints
#   render.nix   authored shape -> engine wire JSON
#   parse.nix    engine wire JSON -> authored shape, so EXISTING definitions
#                can be checked and so parse/render round-trips are testable
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
  parse = import ./parse.nix {inherit lib;};
  render = import ./render.nix {inherit lib;};
in {
  inherit analyze parse render types;

  # Engine constants, for consumers that need to reason about the caps
  # (e.g. sizing a fan-out against the 20-step ceiling) without importing
  # the option types.
  inherit (types) engine;
}

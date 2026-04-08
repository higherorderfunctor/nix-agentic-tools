# AI ecosystem package.
#
# passthru.transforms is a backward-compatibility shim that delegates
# to the per-ecosystem records in lib/ai-ecosystems/. The shim
# preserves the byte-identical output contract — existing consumers
# see no change.
#
# Phase 2's backend adapters will consume the records directly via
# passthru.records and stop using the transforms shim.
_: final: _prev: let
  inherit (final) lib;
  fragmentsLib = import ../../lib/fragments.nix {inherit lib;};

  # Load all ecosystem records — single source of truth for the
  # markdown transformer logic.
  records = {
    claude = import ../../lib/ai-ecosystems/claude.nix {inherit lib;};
    copilot = import ../../lib/ai-ecosystems/copilot.nix {inherit lib;};
    kiro = import ../../lib/ai-ecosystems/kiro.nix {inherit lib;};
    agentsmd = import ../../lib/ai-ecosystems/agentsmd.nix {inherit lib;};
  };

  # Build a back-compat transform function from an ecosystem record.
  # The legacy API was `transforms.<eco> [extras] fragment -> string`,
  # where extras is the curried context (e.g., { package = "X"; }
  # for claude, { name = "X"; } for kiro). The shim threads extras
  # through mkRenderer's ctxExtras parameter.
  mkLegacyTransform = record: extras: fragment: let
    render = fragmentsLib.mkRenderer record.markdownTransformer extras;
  in
    render fragment;
in {
  fragments-ai =
    final.runCommand "fragments-ai" {} ''
      mkdir -p $out/templates
      cp ${./templates}/*.md $out/templates/
    ''
    // {
      passthru = {
        # New API: ecosystem records consumed by Phase 2 adapters.
        inherit records;

        # Back-compat API: function-based transforms preserving the
        # exact signatures from the old packages/fragments-ai/default.nix.
        transforms = {
          # transforms.claude { package = "X"; } fragment
          claude = extras: fragment: mkLegacyTransform records.claude extras fragment;

          # transforms.copilot fragment (no extras)
          copilot = fragment: mkLegacyTransform records.copilot {} fragment;

          # transforms.kiro { name = "X"; } fragment
          kiro = extras: fragment: mkLegacyTransform records.kiro extras fragment;

          # transforms.agentsmd fragment (no extras)
          agentsmd = fragment: mkLegacyTransform records.agentsmd {} fragment;
        };
      };
    };
}

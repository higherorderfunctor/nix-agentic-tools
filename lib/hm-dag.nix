# Minimal home-manager DAG helpers.
#
# Provides lib.hm.dag.{entryAfter,entryBefore,entryAnywhere} for use
# in activation scripts. These are compatible with home-manager's DAG
# system — when evaluated inside a real HM config, HM's own lib.hm
# takes precedence (via lib.extend's prev.hm check in the module
# entry points). This fallback exists so nix flake check can evaluate
# the modules without a full HM context.
_: {
  entryAnywhere = data: {
    text = data;
    after = [];
    before = [];
  };

  entryAfter = after: data: {
    text = data;
    inherit after;
    before = [];
  };

  entryBefore = before: data: {
    text = data;
    inherit before;
    after = [];
  };
}

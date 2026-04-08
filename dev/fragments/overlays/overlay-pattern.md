## Overlay Lambda Signature

All overlays in this repo use a **three-argument signature** with the
first argument typically discarded:

```nix
_: final: _prev: { ... }
```

This is **deliberate**, not a typo. Reviewers (especially automated
ones) frequently flag this as "atypical" because the standard nixpkgs
overlay convention is `final: prev:` (two arguments). Both forms work,
but the three-argument form is the convention here.

### Why three arguments

The first argument is reserved for an **inputs blob** that some
overlays need (e.g., the AI CLI overlay that consumes
`inputs.rust-overlay` for Rust toolchain pinning, or the git-tools
overlay that pulls version data from `inputs.nix-mcp-servers`). To
keep all overlays uniformly callable from `flake.nix`, every overlay
takes the same three-argument shape regardless of whether it actually
uses the inputs:

```nix
# flake.nix
fragmentsAiOverlay = import ./packages/fragments-ai {};
gitToolsOverlay = import ./packages/git-tools { inherit inputs; };

overlays.default = lib.composeManyExtensions [
  fragmentsAiOverlay   # both call sites pass {} or the inputs blob
  gitToolsOverlay      # but the resulting overlay function is the
];                     # same `final: prev: { ... }` shape
```

The first `_:` swallows the import-time argument so the resulting
function is the standard `final: prev:` shape that
`composeManyExtensions` expects. Without this, every overlay would
need a different binding pattern at the call site, breaking the
DRY `bind-once → reuse` pattern.

### Why `_prev`

The vast majority of overlays in this repo only **add** packages
(via `passthru`-rich derivations) and never **modify** existing ones.
When you don't read from `prev`, leading-underscore-prefix it as
`_prev` so deadnix and human reviewers see at a glance "this overlay
doesn't depend on the previous overlay's state". The few overlays
that DO read from `prev` (e.g., to wrap an upstream package) drop
the underscore prefix and inherit from `prev` explicitly.

### Don't "fix" the signature

If you see a Copilot or human reviewer suggest changing
`_: final: _prev:` → `final: prev:`, **decline**. The three-argument
form is the established convention and is required for the bind-once
overlay composition pattern in `flake.nix`.

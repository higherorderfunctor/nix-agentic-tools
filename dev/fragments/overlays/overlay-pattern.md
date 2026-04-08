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
overlays may need (e.g., a future AI CLI overlay that consumes
`inputs.rust-overlay` for Rust toolchain pinning, or a git-tools
overlay that pulls version data from external inputs). To keep all
overlays uniformly callable from `flake.nix`, every overlay takes the
same three-argument shape regardless of whether it actually uses the
inputs.

After the factory rollout (Milestones 1–10), the overlays at the
flake level are split between the unified binary-package overlay
(`./overlays`, which consumes `inputs` for cache-hit parity via
per-package `ourPkgs`) and the content-only overlays under
`packages/` (which don't need extra flake inputs and are called
with an empty `{}`). All keep the same three-argument shape so
all overlays remain uniformly callable from `flake.nix`'s
`bind-once → reuse` composition pattern:

```nix
# flake.nix
aiOverlay = import ./overlays {inherit inputs;};           # NEW — all binary drvs under pkgs.ai.*
codingStandardsOverlay = import ./packages/coding-standards {};
stackedWorkflowsOverlay = import ./packages/stacked-workflows {};

overlays.default = lib.composeManyExtensions [
  nvSourcesOverlay          # exposes `final.nv-sources` from nvfetcher
  aiOverlay                 # 24 binary packages under pkgs.ai.*
  codingStandardsOverlay    # content package
  stackedWorkflowsOverlay   # content package
];
```

The content overlays (`codingStandardsOverlay`,
`stackedWorkflowsOverlay`) are called with an empty `{}` first
argument because they don't need flake inputs. The binary
overlay (`aiOverlay`) consumes `{inherit inputs;}` because its
per-package files in `overlays/<name>.nix` need `inputs.nixpkgs`
for cache-hit parity and `inputs.rust-overlay` for Rust toolchain
pinning. The first `_:` (or `{...}:`) swallows the import-time
argument so the resulting function is the standard
`final: prev:` shape `composeManyExtensions` expects regardless.
Without this, overlays that need inputs would have a different
binding pattern at the call site than overlays that don't, breaking
the DRY composition.

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

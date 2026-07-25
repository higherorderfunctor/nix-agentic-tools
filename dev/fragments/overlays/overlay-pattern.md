## Overlay Grouping and the `generic` Subtree

> **Last verified:** 2026-07-25 (commit pending — records the
> namespaced-only rule and the store-path-parity expectation for thin
> nixpkgs overrides). If you add, remove or rename an overlay namespace,
> move a package between namespaces, or change how a `generic` package
> relates to its nixpkgs original, and this section isn't updated in the
> same commit, stop and fix it.

`overlays/default.nix` aggregates per-package files into grouped
namespaces: `pkgs.ai.*` (plus its `mcpServers` / `lspServers`
sub-groups), `pkgs.devTools.*`, `pkgs.generic.*`, and
`pkgs.gitTools.*`. Every group is built the same way — an attrset of
`import ./<dir>/<name>.nix {inherit inputs final;}` entries, passed
through `guard` (the unfree wrapper) in the output set, and flattened
into `packages.<system>` in `flake.nix` for CLI ergonomics — so a new
group is one attrset, one output line, and one flatten line.

`generic` is the group defined by what it is NOT: packages with nothing
agentic about them, living in `overlays/generic/` and earmarked for a
possible future repo split. The grouping exists so that split is a
directory move rather than an archaeology exercise, which means the
subtree must not acquire dependencies on the rest of the repo beyond
`overlays/lib.nix`. Judge membership by whether the package would make
sense in a repo called "agentic tools" — a hardened Firefox preference
set, a btop theme, the DNS root hints, a resource monitor, a JS runtime
and a JSON log viewer do not.

Two mechanical consequences of living in a subdirectory rather than at
the `overlays/` root:

- `vu = import ../lib.nix` (one level up), not `./lib.nix`.
- The update helpers default `sourcesFile` to
  `overlays/<pname>-sources.json`, which is wrong here, so grouped
  packages pass `sourcesFile` explicitly. The sidecar lives beside the
  package file.

Nothing else is relaxed: cache-hit parity applies in full (see that
fragment — shipping data files is NOT the same as being content-only),
each package gets a `config.checks.cacheHitParity` row, and each
version-tracked one gets a `config.update.targets` row.

### Thin overrides of a nixpkgs package

Several `generic` entries (`btop`, `bun`, `fblog`) are not fresh
derivations but `ourPkgs.<name>.overrideAttrs` over the nixpkgs one,
moving only `version`, `src` and `passthru.updateScript`. Two rules
that are not obvious from reading such a file:

- **Namespaced-only.** The overlay writes `pkgs.generic.<name>` and
  NEVER a top-level `pkgs.<name>`. Shadowing a nixpkgs attribute would
  turn this from an additive overlay into one that silently re-points
  every unrelated consumer of that package; the additive contract is
  what lets consumers apply the overlay without auditing it.
- **An identical store path is EXPECTED, not a bug.** While our sidecar
  pin and nixpkgs' pin name the same version, a thin override yields
  the byte-identical derivation — a fixed-output `src` path follows its
  hash, not its fetcher, so a `fetchzip` of the repo-archive tarball
  lands on the same path `fetchFromGitHub` does. The package still
  earns its place: it rides this repo's 4x/day update sweep instead of
  a nixpkgs channel bump, and the paths diverge the moment upstream
  moves. Do not "clean up" such a package on parity grounds.

Rust packages on this pattern have one extra constraint.
`ghArchiveUpdateScript` refreshes only the src hash in the sidecar, so
an inline `cargoHash` would go stale on every bump — the known
transitive-hash gap. Override `cargoDeps` with
`rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }`
against the PINNED src instead, so one hash covers both and the vendor
set self-updates.

**The CI IFD warm step does not cover that kind of IFD.**
`.github/actions/warm-ifd` pre-realizes sources by evaluating
`p.version or p.name or "unknown"` across the package set. That works
for packages whose version is `readFile`-derived FROM the source — the
read forces the fetch. It does nothing for a package whose version
comes from a `-sources.json` sidecar and whose only IFD is
`cargoLock.lockFile`: `.version` resolves from the sidecar and
short-circuits before `drvPath` (and therefore `cargoDeps`) is ever
forced. Measured on `fblog` with `--option
allow-import-from-derivation false`: `.version` evaluates clean,
`.drvPath` fails with `cannot build '…-source.drv^out' during
evaluation`. Not a build break — the later eval simply fetches the
source itself, without the warm step's retry/backoff — but do not
assume a sidecar-versioned package is warmed just because it is in
`packages`.

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
aiOverlay = import ./overlays {inherit inputs;};           # every grouped drv namespace
codingStandardsOverlay = import ./packages/coding-standards {};
stackedWorkflowsOverlay = import ./packages/stacked-workflows {};

overlays.default = lib.composeManyExtensions [
  aiOverlay                 # 27+ packages: pkgs.ai.*, pkgs.devTools.*,
                            # pkgs.generic.*, pkgs.gitTools.*
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

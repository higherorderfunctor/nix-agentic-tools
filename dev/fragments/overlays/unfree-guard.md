## Unfree Package Guard (`ensureUnfreeCheck`)

> **Last verified:** 2026-04-13 (commit pending). If you touch
> `overlays/default.nix`, add a new unfree package to any overlay,
> or change how `guard` is applied to output attrsets and this
> fragment isn't updated in the same commit, stop and fix it.

### The problem

Nix overlays that build unfree packages with `ourPkgs` (pinned
nixpkgs, `config.allowUnfree = true`) silently bypass the
consumer's unfree preference. The nixpkgs unfree check
(`pkgs/stdenv/generic/check-meta.nix`) fires at `mkDerivation`
eval time, bound to the nixpkgs instance's config — not the
consumer's. Once a permissive `ourPkgs` produces the derivation,
the consumer gets the pre-evaluated result with no check.

### The solution

`overlays/default.nix` defines `ensureUnfreeCheck`:

```nix
isUnfree = drv: let
  license = drv.meta.license or {};
in
  if builtins.isList license
  then builtins.any (l: !(l.free or true)) license
  else !(license.free or true);

ensureUnfreeCheck = drv:
  if isUnfree drv
  then
    final.symlinkJoin {
      inherit (drv) name version;
      paths = [drv];
      meta = drv.meta or {};
      passthru = drv.passthru or {};
    }
  else drv;

guard = builtins.mapAttrs (_: ensureUnfreeCheck);
```

Applied universally at the output level:

```nix
{ ai = guard flatDrvs // {
    mcpServers = guard (mcpServerDrvs // {agnix-mcp = agnixMcp;});
    lspServers = guard {agnix-lsp = agnixLsp;};
  };
  gitTools = guard gitToolDrvs;
}
```

### How it works

1. `ourPkgs` (overlay-internal, `allowUnfree = true`) builds the
   real derivation. CI pushes it to cachix.
2. `ensureUnfreeCheck` inspects `meta.license.free`. If unfree,
   wraps in `final.symlinkJoin` (consumer's nixpkgs) carrying
   `meta = drv.meta`. The consumer's `check-meta.nix` fires on
   the wrapper — standard error if they haven't set `allowUnfree`.
3. If free, returns the derivation unwrapped (zero overhead).
4. Applied via `builtins.mapAttrs` — new packages are
   automatically guarded.

### Cache-hit parity is preserved

The unfree check is purely eval-time (`check-meta.nix`). It does
NOT affect derivation hashes. The wrapper's dependency on the
real derivation (from `ourPkgs`) has the same store path CI
built, so cachix serves it.

### Consumer UX

- Consumer without `allowUnfree` -- standard nixpkgs unfree error
- Consumer with `allowUnfree = true` -- works, cached from cachix
- Consumer with `allowUnfreePredicate` -- works for allowed pkgs
- Free packages -- no wrapper, pass through, zero overhead

### This pattern is novel

No existing community solution was found (researched 2026-04-10):

- numtide/nixpkgs-unfree: complete fork, bypasses consumer pref
- Discourse advice: "just set allowUnfree" when importing
- Official nixpkgs/Hydra: does NOT build unfree at all

Our wrapper pattern appears unique in the Nix ecosystem. Document
any changes to it thoroughly.

### When adding new packages

No manual per-package work needed. The `guard` function wraps
everything at the output level. Just ensure your new package's
`meta.license` is set correctly — the guard reads it to decide
whether to wrap.

### Packages currently unfree

- `claude-code` (proprietary)
- `copilot-cli` / `github-copilot-cli` (proprietary)
- `kiro-cli` / `kiro-gateway` (proprietary)

All other packages (MCP servers, git tools, agnix) are free and
pass through the guard unwrapped.

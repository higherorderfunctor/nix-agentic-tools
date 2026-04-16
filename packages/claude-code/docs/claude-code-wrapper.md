## claude-code Wrapper Chain

> **Last verified:** 2026-04-15 (buddy removal — anthropics/claude-code#45517).
> If you touch `overlays/claude-code.nix` or the HM plugin wrapper
> integration and this fragment isn't updated in the same commit,
> stop and fix it.

Claude Code ships as a **pre-built compiled binary** (a Bun
single-exec). The base package (`overlays/claude-code.nix`)
installs it directly as `$out/bin/claude`.

### The chain

```
claude             (HM plugin wrapper, from nixpkgs claude-code module)
  → $out/bin/claude  (pre-built binary from overlays/claude-code.nix)
```

1. **HM plugin wrapper** (`$out/bin/claude`): a short bash script
   produced by nixpkgs' `programs.claude-code` module. It execs
   the underlying binary with a `--plugin-dir <store-path>`
   argument pointing at a generated plugin store path.
2. **Pre-built binary**: the compiled Bun single-exec fetched from
   Anthropic's GPG-signed manifest. Bun is embedded in the
   binary — no external Bun dependency needed at runtime.

### The base package

`overlays/claude-code.nix` builds a `stdenv.mkDerivation` that
fetches the platform-specific pre-built binary from Anthropic's
manifest and installs it as `$out/bin/claude`. Per-platform sources
are tracked in `overlays/claude-code-sources.json`, managed by
the package's `updateScript`.

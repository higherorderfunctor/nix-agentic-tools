# claude-code npm distribution removal contingency

> Extracted from `docs/plan.md` during 2026-04-07 backlog grooming.
> Full long-form version of the "claude-code npm distribution
> removal" backlog item. Referenced by a short item in plan.md.

## The risk

Anthropic soft-deprecated npm distribution 2026 ("npm installation
is deprecated" per https://code.claude.com/docs/en/setup). The
native installer is a Bun-compiled single-exec fetched from a
GPG-signed manifest. If Anthropic eventually stops publishing to
npm entirely, our buddy patching pipeline breaks because `cli.js`
is no longer a file on disk — it's embedded inside the Bun
single-exec format's data section.

## Current state

- Pipeline uses `@anthropic-ai/claude-code` (npm, `buildNpmPackage`)
- Wraps `bin/claude` with a Bun runtime wrapper that execs
  `bun run $CLI`
- Activation script patches `cli.js` (15-byte salt marker
  `friend-2026-401`)
- A snackbar warning fires on every launch because
  `Zj() = typeof Bun < 'u' && Bun.embeddedFiles.length > 0`
  returns false for us (we're running a plain cli.js, not a
  compiled exec with embedded assets). Suppressible via
  `DISABLE_INSTALLATION_CHECKS=1` env var.

## nvfetcher migration (easy)

The native installer distribution URL is documented and
predictable:

```
https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/
  claude-code-releases/<VERSION>/
    manifest.json        — lists platforms + SHA256 per binary
    manifest.json.sig    — detached GPG signature (from 2.1.89+)
    <platform>/claude    — the compiled single-exec
```

GPG key at `https://downloads.claude.ai/keys/claude-code.asc`,
signed by "Anthropic Claude Code Release Signing
<security@anthropic.com>". Fingerprint published in the setup docs
under "Verify the manifest signature" — check the live docs at
migration time rather than embedding a rotatable value here.

Migration pattern: swap `claude-code.nix` from `buildNpmPackage`
override to `prev.claude-code.overrideAttrs` fetching the binary —
**exactly the same pattern already used by `kiro-cli.nix` and
`copilot-cli.nix`**. nvfetcher gets a custom `fetch.file` strategy
polling `manifest.json`, plus per-platform SHA256 hashes tracked in
`hashes.json` sidecar. Maybe an afternoon of work.

## Buddy pipeline options (hard, partially blocked)

When the native installer replaces the npm distribution, the
buddy-patching flow has four possible fallbacks. Three are viable;
one is blocked by closed source.

### Option 1: Pin last-known-good npm version

nvfetcher already tracks srcHash; just freeze. Buddy keeps working
against a stale cli.js, no updates. Ugly but the minimum-viable
fallback. Cost: miss new claude-code features until the day
Anthropic actually removes the old npm version from the
registry.

### Option 2: Patch the compiled binary's embedded section

The Bun single-exec format is documented (sort of) but fragile —
the format can change between Bun versions. Would need to unpack
the data section, find and replace the salt bytes, re-pack, re-sign
(macOS). High maintenance, breakage risk on every claude-code
version bump.

### Option 3: Compile our own with a patched source (BLOCKED)

Would mean fetching the source separately (not the pre-compiled
binary), applying the salt patch at build time, running
`bun build --compile` in a nix derivation. This is the OLD
`withBuddy` build-time approach — we already abandoned it for good
reasons (no sops support, multi-user broken, stale companion
field), but those concerns could be reintroduced differently by
computing the salt at activation time and only running compile
when fingerprint changes (expensive activation step, not
build-time).

**BLOCKED BY CLOSED SOURCE.** The big claude-code sourcemap leak
2026 confirmed the binary is NOT entirely open source —
significant portions are proprietary. Even if we could obtain a
source tree (via the leaked maps or by reverse-engineering from
npm), redistributing or recompiling would be legally murky and
would leave nixpkgs policy compliance (we can't ship
non-redistributable source). This likely rules option 3 out
entirely, leaving options 1 and 2 as the only viable long-term
paths.

### Option 4: Drop buddy patching entirely

Just accept whatever buddy the default salt produces. Cosmetic loss
only — claude-code still works.

## Recommended posture now

Monitor. Check `@anthropic-ai/claude-code` npm publish frequency
periodically. If Anthropic slows down or stops npm releases while
the native channel keeps updating, that's the signal. Also watch
for changes in the sourcemap situation — if more source becomes
public or Anthropic publishes an official source tree, option 3
moves back into play.

## Touch points when migration happens

- `nvfetcher.toml` — change `claude-code` entry's fetch strategy
  (GitHub releases? custom file fetcher? we already have
  `fetch.url` in the toolbox)
- `packages/ai-clis/claude-code.nix` — switch from
  `buildNpmPackage` override to `overrideAttrs` binary fetch (copy
  the `copilot-cli.nix` shape)
- `packages/ai-clis/hashes.json` — swap `npmDepsHash` / `srcHash`
  for per-platform binary hashes
- `modules/claude-code-buddy/default.nix` — decide which buddy
  option above, update accordingly
- `dev/docs/guides/buddy-customization.md` — document whatever
  fallback we land on
- Possibly delete `packages/ai-clis/locks/claude-code-package-lock.json`
  (no longer needed when we stop using buildNpmPackage)

## Related

- `packages/ai-clis/fragments/dev/buddy-activation.md` — scoped
  architecture fragment that describes the current pipeline
- `dev/fragments/overlays/cache-hit-parity.md` — separate issue but
  related: both care about nvfetcher and overlay build
  infrastructure

## MCP Server Packages

> **Last verified:** 2026-09-20 — vendored npm lock locations follow their
> manual or automatic updater.
>
> Full lineage: `git show ed5898b1:dev/fragments/mcp-servers/overlay-guide.md`.

### Overlay Architecture

MCP recipes live under
`packages/<owner>/packages/ai/mcpServers/<server>/package.nix`. Native discovery
exposes them at `pkgs.ai.mcpServers.*` and flat flake package outputs. The
composer injects pinned `pkgs` and shared `packageLib`; owner-private libraries,
patches, and source sidecars stay beside the owner registry.

### Build Patterns

Servers use one of three Nix builders depending on upstream language:

- **npm** (`buildNpmPackage` / pnpm override) — aihubmix-mcp, context7-mcp,
  effect-mcp, git-intel-mcp, gitlab-mcp. Require `pnpmDeps` or `npmDeps` hash
  inline in the owner recipe
- **Python** (`buildPythonApplication`) — kagi-mcp, mcp-proxy, sympy-mcp. Some
  use `pyproject = true` with hatchling or setuptools
- **Go** (`buildGoModule`) — github-mcp. Requires `vendorHash` inline in the
  owner recipe

Semble is the explicit non-builder exception. `semble-mcp` is a plain attr/meta
view of `inputs.llm-agents.packages.${system}.semble`: it changes
`meta.mainProgram` and shares the upstream CLI's exact derivation. It has no
local source pin or update-target row; normal flake-input automation updates
`llm-agents`.

### Inline Hash Pattern

Each package pins `rev` and `hash` directly in its native `package.nix` recipe.
No sidecar files or generated sources — everything is visible in one place:

```nix
# packages/context7-mcp/packages/ai/mcpServers/context7-mcp/package.nix
rev = "c31528d...";
src = ourPkgs.fetchFromGitHub {
  owner = "upstash";
  repo = "context7";
  inherit rev;
  hash = "sha256-TMvDzD...";
};
```

Version is computed at eval time from the source manifest via `mkVersion`:

```nix
version = vu.mkVersion {
  upstream = vu.readPackageJsonVersion "${src}/packages/mcp/package.json";
  inherit rev;
};
# → "1.2.3+c31528d"
```

Dependency hashes (pnpmDeps, vendorHash) are also inline in the same file.

### An npm-REGISTRY server is not a GitHub server

`aihubmix-mcp` is the one server sourced from an npm-registry tarball rather
than a git repo, and three things follow that do NOT follow for the
`fetchFromGitHub` / `fetchgit` servers above:

- **No rev, so no `vu.mkVersion` and no `vu.readPackageJsonVersion`.** A flat
  `fetchurl` yields the `.tgz` FILE, not a tree, so there is nothing to
  `readFile` at eval time — and the URL embeds the version anyway. The version
  is a literal, and `sourceRoot = "package"` because npm tarballs extract under
  `package/`.
- **`vu.ghArchiveUpdateScript` / `vu.ghLatestVersionCmd` do not transfer**, on
  two counts: the source is not GitHub-hosted, and `ghArchiveUpdateScript`
  records a `nix-prefetch-url --unpack` hash — the UNPACKED-NAR value, which
  fails a flat `fetchurl`'s fixed-output check. For npm, the version source is
  the registry document's `dist-tags` (see `packages/pnpm/lib/mkMajor.nix` for
  the `curl … | jq -r '.["dist-tags"]…'` shape).
- **npm publishes no lockfile in the tarball**, but `fetchNpmDeps` requires one.
  For a manually regenerated lock, vendor it under the owner directory as
  `packages/<owner>/src/<name>-package-lock.json` and `cp` it in from
  `postPatch`. Automated generators may require a different location; follow
  `dev/fragments/packaging/naming-conventions.md`. Formatter and spelling
  exclusions cover standard and prefixed npm lock names; npm owns their
  formatting.

### A local patch is an update-cadence decision, not a detail

`patches = [ ./<name>-<topic>.patch ]` against upstream's PUBLISHED BUILD OUTPUT
(not source) is maximally fragile: any upstream rebuild of the patched file
breaks it, and no update script can re-author a patch.

The decision this drives is about SWEEPABILITY, not about which version to
carry. Tracking `dist-tags.latest` is normal and expected; what the patch costs
is the ability to get there AUTOMATICALLY. A targets row on such a package goes
RED the first time upstream rebuilds the patched file, occupying a channel meant
for TRANSIENT failures. So carry whatever version the operator wants, bump it BY
HAND, and make the machinery honest:

1. a `config.update.excludePatterns` entry recording the exclusion and why;
2. a non-blocking annotation step in `.github/workflows/update.yml` — the family
   that already holds the copilot-cli SEA detector and the pnpm new-major
   detector — comparing upstream's version against one DERIVED from the repo
   (`nix eval --raw .#packages.<system>.<name>.version`), never a literal;
3. the reasoning, measured, in the recipe's own header.

Keep the two mechanisms mutually exclusive: excludePattern + detector, OR a
targets row — never both. The day the patch can be dropped (upstream grows the
feature, or the change lands upstream), delete the exclusion and the detector in
the SAME commit that adds the targets row.

`aihubmix-mcp` is the worked example, and it also shows the trap: when it moved
to `dist-tags.latest` the patch had to be re-authored by hand (hunk 1 applied
with fuzz, hunks 2 and 3 failed outright), which is precisely why being current
did not make it sweepable. Structure such a patch to minimize anchors — a single
contiguous prepend at the top of the file, where upstream's first import lines
are the most stable context available, plus the smallest possible insertions
elsewhere. And confirm it applies with NO fuzz: `patch` taking a hunk with fuzz
means it guessed at the location.

### Patching SOURCE keeps its targets row — the rule above is about dist

Everything above is scoped to patching upstream's published BUILD OUTPUT. A
package that builds from source in-tree (runs `tsc` / `cargo` / `go build`
itself) is a different class, and the exclusion-plus-annotation dance is the
WRONG shape for it:

- Source anchors track upstream's own code, which moves far less often than a
  rebuilt `dist/`. The aihubmix failure mode — a rebuild with no source change
  invalidating every hunk — cannot occur.
- Express it as `substituteInPlace … --replace-fail` in `postPatch`, not as a
  `.patch` file. `--replace-fail` is positional-anchor-free and turns drift into
  a loud build failure; a `.patch` can apply with FUZZ and silently land in the
  wrong place.
- So keep the `config.update.targets` row. A sweep that goes red here is the
  SIGNAL, not a channel-occupying nuisance: it means upstream touched the exact
  lines being patched, which is precisely when a human must look.

For a SECURITY patch that inverts an upstream default, a failing build is the
DESIRED outcome — auto-sweeping past it would silently restore the unsafe
default.

**Since the hold-back split (2026-09-09) that failure surfaces as a RED PR, not
as a held-back target.** The protection is unchanged and does not depend on
hold-back: `build (<system>)` is a required status check, so a dead
`--replace-fail` anchor reddens it and the bot's auto-merge cannot land the PR.
What moved is only WHERE you see it — a red check on an open PR rather than a
`HELD BACK` line in a sweep log, which is the more visible of the two. Do not
"restore" hold-back here on safety grounds; the required check is the gate.
Prefer edits that also make the compiler your backstop: if the patched signature
is threaded through callers, a partial application fails to typecheck rather
than compiling into a half-patched binary.

`openmemory-mcp` WAS the worked example, and its whole arc is the lesson — the
package was retired on 2026-09-01, but keep the example: this repo carries no
other source-level security patch, and a rule with a retired illustration beats
a rule with none.

Upstream called `listen(port)` with no host and shipped no bind knob, so the
daemon bound every interface. The overlay patched `src/core/cfg.ts`,
`src/server/server.ts` and `src/server/index.ts` to thread a required `host`
defaulting to loopback, backed by a `postInstallCheck` positive control and
negative-control-verified (neutering `postPatch` reddened the build; breaking an
anchor reddened `substituteInPlace`).

TWO THINGS IT PROVED, both worth carrying forward. First, the held-back sweep
worked exactly as designed: when upstream renamed itself and rewrote the tree,
every `--replace-fail` anchor died and the sweep STOPPED rather than
auto-sweeping past a broken security patch. That is the whole point of
preferring `--replace-fail` over a tolerant substitution. Second, the patch's
own success condition was upstream adopting the fix — which it eventually did,
defaulting to `127.0.0.1` and threading the host through its listeners. A source
patch that inverts an unsafe upstream default is a bet that upstream comes
around; plan for the patch to be DELETED, not maintained forever.

### Adding a New Server

1. Create the owner recipe under `packages/<owner>/packages/ai/mcpServers/`. Use
   the appropriate builder and route build inputs through pinned `pkgs`.
2. Put patches and vendored source files in the owner's `patches/` and `src/`.
   For generated lockfiles, follow the updater's output location as described
   above.
3. Contribute update, cache-parity, and `documentation.mcpServerMeta` rows in
   the owner's `registry.nix`. Adding the native recipe needs no root edit.
4. Export consumer factories through the owner's `lib/default.nix`. Managed
   services also need their service module and backend integration.
5. Add package checks beside the implementation, then regenerate with
   `devenv tasks run --mode before generate:all`.

For an external package role such as `semble-mcp`, replace the local build and
update target with a direct input-package selection and input update automation.
Still register both the CLI and MCP roles in cache-hit parity, and add a
sibling-derivation assertion so a future `overrideAttrs` cannot create a
redundant build.

### Updating

```bash
nix build .#<server-name>       # Build a single server
nix run .#update                # Run all updates via config.update.targets
nix flake check                 # Verify evaluation
```

Updates use two mechanisms depending on package type:

- **Main-tracking packages**: `mkGitRevUpdateScript` fetches the latest commit
  via `git ls-remote`, then `nix-update --version skip` refreshes all hashes
- **Per-platform binaries**: `mkUpdateScript` fetches the latest release
  version, prefetches each platform's binary, and writes to `sources.json`. For
  a GitHub-released upstream, pair it with `ghLatestVersionCmd` (reads the
  `releases/latest` redirect — no API token, no rate limit) instead of
  hand-rolling a `curl api.github.com | jq` version check.

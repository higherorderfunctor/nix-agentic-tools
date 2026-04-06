# Update System Design

Redesign the package update pipeline from a hardcoded bash script
(`scripts/update`) into Nix-generated devenv tasks with auto-discovery.

## Problem

The current `scripts/update` hardcodes package names, hash types, and
lockfile strategies. Adding a new package requires editing the script in
multiple places. The script also had a bug where `fetchurl` hashes were
passed to `fetchzip` (different output, different hash), and nixpkgs'
`postPatch` overwrote our lockfile causing `npmDepsHash` mismatches.

The hash bugs are fixed (commits `2bcbd09`, `99fabe1`), but the
hardcoding and lack of granularity remain.

## Goals

- **Auto-discovery:** derive package lists, hash types, source types,
  and lockfile paths from Nix expressions — no hardcoded package lists
- **Granular tasks:** individually runnable steps for agentic and
  developer workflows (`devenv tasks run update:hashes`)
- **CI-ready:** full pipeline via `devenv tasks run update` using the
  devenv GitHub Action
- **Delete `scripts/update`:** all logic moves into Nix

## Non-goals

- Drift detection (deferred, tracked in plan.md)
- Cachix binary cache integration (separate concern)

## Architecture

```
dev/update.nix             reads generated.nix + hashes.json at eval time
  |                        produces task exec strings via Nix interpolation
  |
  +-- devenv.nix imports   tasks.update:* (granular, DAG-ordered)
  |
  +-- .github/workflows/   devenv tasks run update (via devenv GH Action)
```

Single implementation consumed by all surfaces. No flake app needed —
CI uses the devenv GitHub Action (`cachix/install-nix-action` +
`cachix/cachix-action` + devenv).

### File layout

- `dev/update.nix` — core module (new)
- `devenv.nix` — imports and wires tasks (modified)
- `.github/workflows/update.yml` — CI workflow (new)
- `scripts/update` — deleted

## Auto-discovery via Nix introspection

### Package groups

Overlay groups are discovered by scanning `packages/*/hashes.json`:

```nix
let
  packagesDir = ./packages;
  dirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir packagesDir);
  hashGroups = lib.filterAttrs (_: v: v != null) (lib.mapAttrs (name: _:
    let path = packagesDir + "/${name}/hashes.json";
    in if builtins.pathExists path
       then builtins.fromJSON (builtins.readFile path)
       else null
  ) dirs);
in
  # { ai-clis = { claude-code = { npmDepsHash, srcHash }; };
  #   git-tools = { agnix = { cargoHash }; ... };
  #   mcp-servers = { context7-mcp = { npmDepsHash }; ... }; }
```

Adding a new overlay group: create the directory with `hashes.json`.
No update logic changes.

### Hash types per package

Derived from `hashes.json` field names:

- `npmDepsHash` present -> needs lockfile regeneration + `prefetch-npm-deps`
- `srcHash` present -> needs `nix-prefetch-url --unpack` (fetchzip hash)
- `cargoHash` present -> needs bogus-hash-then-build pattern
- `vendorHash` present -> needs bogus-hash-then-build pattern

### Source types (tarball vs git)

Derived from `generated.nix` via fake fetcher introspection:

```nix
let
  generated = (import ./.nvfetcher/generated.nix) {
    fetchurl = args: { type = "tarball"; inherit (args) url; };
    fetchgit = args: { type = "git"; inherit (args) url rev; };
    fetchFromGitHub = args: { type = "github"; inherit (args) owner repo rev; };
    dockerTools = {};
  };
in
  # generated.<name>.src.type -> "tarball" | "git" | "github"
  # generated.<name>.src.url  -> source URL
```

### Lockfile directories

Discovered via `builtins.pathExists (packagesDir + "/${group}/locks")`.

### Package-to-flake-output mapping

For cargo/vendor hash computation, the bogus-hash-then-build pattern
needs the flake output name (e.g., `nix build .#github-mcp`). This
mapping comes from the nvfetcher key, which matches the flake package
name for all current packages. If a future package diverges, a small
mapping override can be added to `hashes.json` (e.g.,
`"flakeOutput": "github-mcp"`).

## Task structure

Six devenv tasks with DAG ordering:

| Task               | `after`            | Runtime deps                                         | What it does                                                           |
| ------------------ | ------------------ | ---------------------------------------------------- | ---------------------------------------------------------------------- |
| `update:flake`     | —                  | `nix`                                                | `nix flake update`                                                     |
| `update:nvfetcher` | `update:flake`     | `nvfetcher`, `treefmt`                               | Runs nvfetcher, formats output                                         |
| `update:locks`     | `update:nvfetcher` | `curl`, `git`, `nodejs`                              | Regenerates npm lock files (tarball or git clone based on source type) |
| `update:hashes`    | `update:locks`     | `prefetch-npm-deps`, `nix`, `jq`, `nix-prefetch-url` | Computes all hash types for all discovered packages                    |
| `update:verify`    | `update:hashes`    | `nix`, `git`                                         | `nix flake check --no-build`, stages changes                           |
| `update`           | all above          | —                                                    | Meta task, no exec                                                     |

### Hash computation strategies (within `update:hashes`)

**npmDepsHash:** Run `prefetch-npm-deps` on the lockfile in
`packages/<group>/locks/<name>-package-lock.json`. Inject result into
`packages/<group>/hashes.json`.

**srcHash:** Run `nix-prefetch-url --unpack --type sha256 <url>`,
convert to SRI with `nix hash convert`. Inject into hashes.json.
Only for packages with a `srcHash` field.

**cargoHash / vendorHash:** Set a bogus hash
(`sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`), stage the
hashes file, attempt `nix build .#<pkg>`, extract the real hash from
the error output. If the build succeeds with the existing hash, skip.

### Script generation

Each task's `exec` string is generated by `dev/update.nix` using Nix
string interpolation. Package lists, URLs, paths, and hash types are
injected at eval time — the bash code contains no hardcoded package
names.

Example pattern for the hashes task:

```nix
# Nix generates bash that iterates discovered packages
let
  npmEntries = lib.concatMapAttrs (group: pkgs:
    lib.mapAttrs' (name: _: lib.nameValuePair name {
      inherit group;
      lockDir = toString (packagesDir + "/${group}/locks");
      hashFile = toString (packagesDir + "/${group}/hashes.json");
    }) (lib.filterAttrs (_: v: v ? npmDepsHash) pkgs)
  ) hashGroups;
in ''
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
    log "Prefetching npmDepsHash for ${name}"
    hash=$(prefetch-npm-deps "${entry.lockDir}/${name}-package-lock.json" 2>/dev/null)
    inject_hash "${entry.hashFile}" "${name}" "npmDepsHash" "$hash"
  '') npmEntries)}
''
```

## CI workflow

```yaml
name: Update
on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools # TODO: create Cachix cache
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
      - run: nix profile install nixpkgs#devenv
      - run: devenv tasks run update
        # DAG ordering means this runs all tasks including verify
      - uses: peter-evans/create-pull-request@v8
        with:
          branch: auto/update
          commit-message: "chore: update flake inputs and upstream versions"
          title: "chore: update flake inputs and upstream versions"
```

## Bash standards

All generated bash follows repo coding standards:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

Devenv task `exec` strings run in plain bash, so the preamble is
included directly in each generated script string. The `shopt` line
is appended after the `set` flags.

## Migration

1. Implement `dev/update.nix` with all task definitions
2. Wire into `devenv.nix` (replace existing `tasks."update:packages"`)
3. Test: `devenv tasks run update` end to end
4. Test: individual tasks (`devenv tasks run update:hashes`)
5. Add `.github/workflows/update.yml`
6. Delete `scripts/update`

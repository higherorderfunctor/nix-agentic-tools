# Design: Migrate git-branchless from Custom Overlay to Upstream Flake Input

**Date:** 2026-04-11  
**Branch:** refactor/ai-factory-architecture  
**Status:** Design Review  
**Blocked by:** None

## Overview

This document designs the migration of git-branchless from a custom Nix overlay (`overlays/git-tools/git-branchless.nix`) to consuming the upstream flake from https://github.com/arxanas/git-branchless.

Current custom overlay adds:
- Rust 1.88.0 pin (workaround for esl01-indexedlog build failure on Rust 1.89+)
- fetchFromGitHub with inline rev+hash
- cargoHash inline
- postPatch = null
- doInstallCheck = false (versionCheckHook stripped)
- Custom version string with +shortrev suffix via overlays/lib.nix

Upstream flake provides a pre-built overlay that integrates git-branchless with nixpkgs' base derivation and manages source/Cargo.lock directly.

---

## Design Questions & Answers

### 1. What does upstream provide?

**Upstream flake structure** (arxanas/git-branchless master):

```nix
outputs = { self, nixpkgs, ... }:
  {
    overlays.default = (final: prev: {
      git-branchless = prev.git-branchless.overrideAttrs ({ meta, ... }: {
        src = self;                           # Points to repo HEAD
        cargoDeps = final.rustPlatform.importCargoLock {
          lockFile = ./Cargo.lock;            # Committed lock file
        };
        # Removes maintainers from meta, keeps other meta fields
      });
      scm-diff-editor = ...;
    });
    packages = { git-branchless, scm-diff-editor, ... };
    checks = { git-branchless = ...; };
  }
```

**Key observations:**

1. Upstream overlay uses `self` (repo HEAD) as the source, not a pinned rev
2. Uses `cargoDeps = importCargoLock` instead of inline cargoHash (equivalent but committed Cargo.lock provides reproducibility)
3. No custom Rust version pin — uses nixpkgs' default rustPlatform and Rust version
4. Removes `maintainers` from meta but preserves version, description, etc.
5. Does NOT strip versionCheckHook — the overlay doesn't override nativeInstallCheckInputs

---

### 2. Can we delete our custom overlay entirely?

**No.** The Rust 1.88.0 pin is still needed because:

- Upstream flake has no Rust version override
- Current nixpkgs (unstable) defaults to Rust >= 1.89
- esl01-indexedlog (git-branchless's transitive dep) fails on Rust 1.89+ (arxanas/git-branchless#1585)
- Upstream maintainers have not published a fix yet

**However, we can layer a minimal override on top of the upstream overlay:**

Instead of a standalone custom overlay, create a thin wrapper that:
1. Imports upstream overlay
2. Applies Rust 1.88.0 pin and disables versionCheckHook
3. Lets upstream handle version, source, cargoHash

---

### 3. Impact on our overlay architecture

**Current:**  
`overlays/default.nix` → `gitToolDrvs.git-branchless` → `import ./git-tools/git-branchless.nix`

**Proposed:**  
`overlays/default.nix` → `gitToolDrvs.git-branchless` → `(upstream overlay applied) + (thin Rust pin wrapper)`

**Changes to overlays/default.nix:**

```nix
gitToolDrvs = {
  git-absorb = import ./git-tools/git-absorb.nix { inherit inputs final; };
  
  # git-branchless: apply upstream overlay, then thin wrapper for Rust pin
  git-branchless =
    (inputs.git-branchless.overlays.default final final).git-branchless
    .override (_: { ... });  # Rust 1.88.0 + strip versionCheckHook
  
  git-revise = import ./git-tools/git-revise.nix { inherit inputs final; };
};
```

**OR create a dedicated overlay file for composability:**

```nix
# overlays/git-tools/git-branchless-overlay.nix
{ inputs, final, ... }:
let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [ inputs.rust-overlay.overlays.default ];
  };
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform { cargo = rust; rustc = rust; };
  upstreamPkg = (inputs.git-branchless.overlays.default final final).git-branchless;
in
upstreamPkg.override (_: {
  inherit rustPlatform;
  nativeInstallCheckInputs =
    builtins.filter
    (p: (p.pname or "") != "version-check-hook")
    (upstreamPkg.nativeInstallCheckInputs or []);
})
```

Then in overlays/default.nix:

```nix
gitToolDrvs = {
  git-absorb = import ./git-tools/git-absorb.nix { inherit inputs final; };
  git-branchless = import ./git-tools/git-branchless-overlay.nix { inherit inputs final; };
  git-revise = import ./git-tools/git-revise.nix { inherit inputs final; };
};
```

**Recommendation:** Use the dedicated overlay file for clarity and consistency with git-absorb/git-revise pattern.

---

### 4. Adding the flake input

**New entry in flake.nix inputs:**

```nix
inputs = {
  # ... existing inputs ...
  git-branchless = {
    url = "github:arxanas/git-branchless";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # ... rest ...
};
```

**No public Cachix cache:** Upstream git-branchless flake does not list a public cache. CI will build locally or via nix-agentic-tools' Cachix.

**devenv.yaml:** No change needed unless devenv explicitly needs git-branchless at eval time. Current devenv.yaml doesn't list git-branchless as an input; it pulls via pkgs overlay. Same will be true post-migration.

---

### 5. Version handling

**Current:** Custom version string "{upstream}+{shortrev}" via overlays/lib.nix:

```nix
version = vu.mkVersion {
  upstream = vu.readCargoVersion "${src}/git-branchless/Cargo.toml";
  inherit rev;
};
```

**Upstream:** Uses nixpkgs' default version derivation, which reads from Cargo.toml directly (no +shortrev suffix).

**Decision:**

- **Option A (Recommended):** Use upstream version as-is. The +shortrev suffix was a workaround for tracking which commit was built; with flake inputs and nix flake update, the version is pinned by lock file instead.
- **Option B:** Keep +shortrev in our thin wrapper. Requires calling vu.readCargoVersion on upstream source (src = self in upstream flake).

**Recommendation:** Option A — upstream version is sufficient. The flake.lock pinning serves the same audit purpose as +shortrev.

**Impact on overlays/lib.nix:** readCargoVersion and mkVersion helpers remain useful for other packages. No removal needed, but git-branchless no longer uses them.

---

### 6. nix-update integration

**Current:** git-branchless listed in config/update-matrix.nix under nixUpdate:

```nix
nixUpdate = {
  git-branchless = "";  # uses nix-update to bump rev+hash
  # ...
};
```

**Post-migration:** Remove git-branchless from nixUpdate. Instead:

```bash
nix flake update git-branchless
```

This updates flake.lock and pins upstream HEAD at the lock commit, matching how nixos-mcp and serena-mcp are managed.

**Changes:**

1. **config/update-matrix.nix:** Remove `git-branchless = "";` from nixUpdate section
2. **Keep in excludePatterns?** No — git-branchless is no longer a "package name" in the nix-update sense; flake input updates are separate

**CI impact:** If CI uses nix-update to bump all packages in update-matrix, git-branchless will be skipped (good). Manual updates use `nix flake update git-branchless` (separate workflow).

---

### 7. Consumer impact

**pkgs.gitTools.git-branchless:**

- Before: Directly from overlays/git-tools/git-branchless.nix
- After: From upstream flake overlay + thin wrapper
- Store path: May differ due to version string change (upstream version instead of +shortrev)
- ABI: Identical binary, same build inputs

**Downstream consumers:**
- Home-manager modules that reference pkgs.gitTools.git-branchless → no change
- Devshell modules that reference pkgs.gitTools.git-branchless → no change
- Skills and CLI tools that use git-branchless → no change

**Cache-hit parity:** Our thin wrapper applies the same Rust pin and versionCheckHook strip as before. Store path will differ from old custom overlay (due to version string), but will be consistent with future updates.

---

### 8. Failure modes and mitigation

| Scenario | Mitigation |
|----------|-----------|
| Upstream repo deleted | Flake input becomes unavailable; nix flake update fails. Mirror flake locally as last resort. |
| Rust 1.89+ issue fixed upstream | Remove thin wrapper, use upstream overlay directly. |
| Upstream changes build process (switches from cargo to meson, etc.) | Thin wrapper may break; monitor upstream releases. |
| Version string change breaks consumers | None expected; consumers don't parse version strings. Document in changelog if store path differs. |

---

## Implementation Plan

### Phase 1: Add flake input (no changes to git-branchless logic)

1. Add `git-branchless` input to flake.nix
2. Run `nix flake update git-branchless` to generate lock entry
3. Verify build: `nix build .#gitTools.git-branchless`

**Expected status:** Build may fail (version mismatch if versionCheckHook runs)

### Phase 2: Create thin wrapper overlay

1. Create overlays/git-tools/git-branchless-overlay.nix with Rust pin + versionCheckHook strip
2. Update overlays/default.nix to import it instead of current git-branchless.nix
3. Verify build succeeds

### Phase 3: Remove nix-update entry

1. Delete `git-branchless = "";` from config/update-matrix.nix
2. Verify dev tasks regenerate correctly
3. Add comment: "git-branchless now updated via nix flake update"

### Phase 4: Cleanup (future)

1. Once upstream fixes Rust 1.89 issue, remove thin wrapper entirely
2. Test with upstream overlay directly
3. Commit removal of Rust pin logic

### Phase 5: Version handling (post-migration assessment)

1. Monitor git-branchless version in first update cycle
2. If downstream breakage occurs (unlikely), add back +shortrev suffix in wrapper
3. Document version scheme in overlays/README.md

---

## Rollback Strategy

If upstream flake becomes unavailable or breaks:

1. **Revert flake input addition:** Remove git-branchless from flake.nix inputs
2. **Restore custom overlay:** Rename overlays/git-tools/git-branchless.nix.bak back to git-branchless.nix
3. **Update overlays/default.nix:** Point gitToolDrvs.git-branchless back to import ./git-tools/git-branchless.nix
4. **Restore nix-update entry:** Add git-branchless back to config/update-matrix.nix

No lock file artifacts remain; git revert is clean.

---

## Testing

After Phase 2 (wrapper implemented):

1. **Build test:** `nix build .#gitTools.git-branchless` succeeds
2. **Flake check:** `nix flake check` passes
3. **Overlay inclusion test:** Verify pkgs.gitTools.git-branchless resolves in multi-platform build
4. **Version string:** `nix eval .#gitTools.git-branchless.version` returns upstream version (no +shortrev)
5. **Binary execution:** Test git-branchless command works (e.g., `git branchless --version`)
6. **Cache-hit parity:** Compare store paths with previous build (expect difference due to version)

---

## Open Questions for Review

1. **Version suffix:** Should we preserve +shortrev for audit trail? Recommend not, but flag if downstream requires it.
2. **devenv.yaml:** Should we add git-branchless input explicitly for clarity, or leave it implicit via flake input?
3. **versionCheckHook strip:** Is this still needed after upstream release? Monitor and remove when safe.
4. **Rust 1.88.0 pin lifecycle:** When upstream fixes esl01-indexedlog, should we remove wrapper immediately or test with Rust 1.89 first?

---

## Related Tickets

- **arxanas/git-branchless#1585** — esl01-indexedlog Rust 1.89+ failure (upstream)
- nix-agentic-tools **Phase 2d (current)** — Monorepo migration, input consolidation

## References

- Upstream flake: https://github.com/arxanas/git-branchless/blob/master/flake.nix
- Current overlay: `/overlays/git-tools/git-branchless.nix`
- Current integration: `/overlays/default.nix` (lines 115–125)
- Update matrix: `/config/update-matrix.nix` (line 20)
- Memory: `/dev/fragments/overlays/overlay-pattern.md` — cache-hit parity pattern

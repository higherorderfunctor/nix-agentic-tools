## Build & Validation Commands

> **Last verified:** 2026-10-22 — generation includes devenv.yaml; lock
> resolution remains an explicit network operation; the Nix CodeQL database task
> reads committed HEAD and runs only when requested.

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural/module eval,
                              # runtime contracts, and validator corpus scans
                              # (does NOT build the package output set)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter the devenv shell with all tools
treefmt                       # Format all files (formats only — lints nothing)
devenv tasks run devenv:git-hooks:run # Manual-stage local all-files diagnostic

# Query committed Nix structure (dev/skills/nix-codeql/SKILL.md).
devenv tasks run codeql:nix-db # Snapshot HEAD; skip a matching source/tool stamp

# Regenerate instructions, repo documents and devenv.yaml. `--mode before` is
# load-bearing: without it devenv runs the aggregate and skips the leaves.
devenv tasks run --mode before generate:all

# After adding or changing a flake input, sync its devenv lock (may use network).
devenv update <input>
```

## Build & Validation Commands

> **Last verified:** 2026-10-26 — context measurements estimate Copilot tuning
> costs; generation includes devenv.yaml; lock resolution remains an explicit
> network operation.

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural/module eval,
                              # runtime contracts, and validator corpus scans
                              # (does NOT build the package output set)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter the devenv shell with all tools
treefmt                       # Format all files (formats only — lints nothing)
devenv tasks run devenv:git-hooks:run # Manual-stage local all-files diagnostic

# Regenerate instructions, repo documents and devenv.yaml. `--mode before` is
# load-bearing: without it devenv runs the aggregate and skips the leaves.
devenv tasks run --mode before generate:all

# After adding or changing a flake input, sync its devenv lock (may use network).
devenv update <input>
```

For context tuning, run `bash dev/scripts/measure-context.sh` for corpus totals
or supply repository-relative paths, including deleted paths:

```bash
bash dev/scripts/measure-context.sh packages/chatgpt-codex/checks/module-eval.nix
```

The initial soft engineering target is **128 KiB for Copilot context plus
matched native instructions**, counting each file once: roughly 32K tokens at 4
bytes/token, with sensitivity about 26K–44K at 5–3 bytes/token. This chosen
target is neither a GitHub limit nor a pass/fail gate. Estimates exclude diff,
system, organization, and retrieved content; path matching approximates native
globs. Local `AGENTS.md` and its child indexes are excluded from Copilot totals.
Codex's configured project-document byte budget is a separate contract.

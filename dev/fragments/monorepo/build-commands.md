## Build & Validation Commands

```bash
nix flake show                              # List all outputs
nix flake check                             # Linters + evaluation (does NOT build packages)
nix build .#<package>                       # Build a specific package
devenv shell                                # Enter devShell with all tools
treefmt                                     # Format all files (Nix, markdown, JSON, TOML, shell)
```

## Regenerating Instruction Files (Always via DevEnv)

When you change a dev fragment, the wired path scoping, or any
content package fragment that feeds the always-loaded monorepo
profile, regenerate the committed instruction files via the
DevEnv task — **never** by running `nix build` + manual `cp`:

```bash
devenv tasks run --mode before generate:instructions:copilot   # .github/copilot-instructions.md + .github/instructions/*
devenv tasks run --mode before generate:instructions:agents    # AGENTS.md
devenv tasks run --mode before generate:instructions:claude    # .claude/rules/* (gitignored, local-only)
devenv tasks run --mode before generate:instructions:kiro      # .kiro/steering/* (gitignored, local-only)
devenv tasks run --mode before generate:instructions           # all four ecosystems
```

The `--mode before` flag is required for DevEnv DAG resolution —
running `devenv tasks run generate:instructions` without it only
runs the umbrella task, not its dependencies.

**Why the task instead of `nix build` + `cp`:**

1. The task is the documented contributor UX. Replicating its
   work manually means you bypass the abstraction you ship and
   make your workflow harder for collaborators to follow.
2. Running the task **exercises** the generation pipeline end to
   end, catching regressions that a manual `nix build` would
   miss (e.g., the cp step's permissions handling, mkdir-on-cp,
   the task DAG itself).
3. The task handles the chmod-after-cp dance so the materialized
   files are writable on first generation.
4. CI drift checks that diff committed files against the task
   output rely on the task being the canonical generator. If
   contributors regenerate via `nix build` but the CI check
   uses the task, divergence becomes possible.

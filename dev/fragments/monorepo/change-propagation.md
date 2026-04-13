## Change Propagation

When removing or renaming a concept, update ALL surfaces that reference
it in the same commit:

- Fragments and generated instruction files
- CLAUDE.md, AGENTS.md, Kiro steering, Copilot instructions
- Routing tables in skills
- README feature matrix and server reference
- flake.nix output lists
- config/update-matrix.nix entries
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references.
The pre-commit hook runs a fast subset. If something is removed, grep
for it across the repo before committing.

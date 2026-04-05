# CLAUDE.md

@AGENTS.md

## Build & Validation Commands

```bash
nix develop                   # Enter devShell with all tools
nix run .#generate            # Regenerate instruction files from fragments
nix fmt                       # Format all files (dprint: Nix + markdown)
```

## Architecture

```
lib/               Shared library: fragments
fragments/         Instruction generation sources (common/ + packages/)
```

## Coding Standards

### Nix

Format with alejandra (via dprint). Use explicit NixOS module types when
writing home-manager modules — never use `types.anything` where a
specific type is known.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to
lists, attribute sets, JSON objects, markdown tables, and similar
collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing
appears twice, extract it. Three similar lines is better than a premature
abstraction, but three similar blocks means it is time to extract.

## Commit Convention

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `style`, `test`

**Scopes** (optional but encouraged): package or module name, directory
name, or `flake` for root changes.

Lowercase, imperative mood, no trailing period.

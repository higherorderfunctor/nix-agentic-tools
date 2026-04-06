## Linting

All code must pass linters before committing:

- **Meta-formatter:** treefmt (orchestrates all formatters below)
- **Nix:** alejandra (format), deadnix (dead code), statix (anti-patterns)
- **Shell:** shellcheck, shellharden, shfmt
- **Markdown:** prettier (via treefmt)
- **JSON:** biome (via treefmt)
- **TOML:** taplo (via treefmt)
- **Spelling:** cspell
- **Agent configs:** agnix

## Build & Validation Commands

```bash
nix flake show                # List all outputs
nix flake check               # Linters + evaluation (does NOT build packages)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter devShell with all tools
nix run .#generate            # Regenerate instruction files from fragments
treefmt                       # Format all files (Nix, markdown, JSON, TOML, shell)
```

## Naming Conventions

- Package overlays: `packages/<group>/<name>.nix`
- Server modules: `modules/mcp-servers/servers/<name>.nix`
- Skills: `packages/stacked-workflows/skills/<name>/SKILL.md`
- Published fragments: `packages/<pkg>/fragments/<name>.md`
- Dev fragments: `dev/fragments/<pkg>/<name>.md`
- update-matrix.nix keys use exported package names (matching the overlay attrset key)
- Exported packages: lowercase with hyphens

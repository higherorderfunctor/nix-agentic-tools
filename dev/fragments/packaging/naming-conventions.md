## Naming Conventions

- Package overlays: `overlays/<group>/<name>.nix` (`mcp-servers`, `lsp-servers`,
  `git-tools`, `dev-tools`, `generic`; ungrouped ones sit at
  `overlays/<name>.nix`)
- Per-package overlay support files: `overlays/<group>/<name>-<kind>.json` /
  `-<kind>.patch` beside the `.nix` — `-sources.json`, `-extracted.json`,
  `-package-lock.json`, `-<topic>.patch`. Flat, never a subdirectory: two
  configs (`treefmt.nix` global excludes, `devenv.nix` cspell excludes) are
  keyed on the `<name>-package-lock.json` glob.
- Server modules: `packages/<name>/modules/mcp-server.nix` — and only for
  servers this repo runs as a managed service (they are enumerated in
  `serverNames` in `packages/mcp-services/modules/homeManager/default.nix`). A
  client-launched stdio server is barrel-only: `packages/<name>/` with
  `lib/mk<Name>.nix` and no `modules/`. The top-level `modules/` directory named
  by earlier revisions of this list no longer exists.
- Skills: `packages/stacked-workflows/skills/<name>/SKILL.md`
- Published fragments: `packages/<pkg>/fragments/<name>.md`
- Dev fragments: `dev/fragments/<pkg>/<name>.md`
- config.update.targets keys use exported package names (matching the overlay
  attrset key)
- Exported packages: lowercase with hyphens

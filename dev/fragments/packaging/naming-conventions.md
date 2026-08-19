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
- Library exports (not packages) name the FILE after the upstream project and
  the ATTRIBUTE after the role, because the two answer different questions:
  `overlays/jail-nix.nix` exports `pkgs.ai.jail`. Everywhere else the file name
  matches the exported key, and that rule still holds for derivations. Here
  `overlays/jail.nix` would collide by eye with upstream's own `lib/jail.nix`,
  and `pkgs.ai.jail-nix.lib` reads as a package named after its packaging. Only
  one such export exists; a second one adopts this shape rather than inventing a
  third.
- Skills: `packages/stacked-workflows/skills/<name>/SKILL.md`
- Published fragments: `packages/<pkg>/fragments/<name>.md`
- Dev fragments: `dev/fragments/<pkg>/<name>.md`
- config.update.targets keys use exported package names (matching the overlay
  attrset key)
- Exported packages: lowercase with hyphens

---
applyTo: "**/*.nix"
---

### Nix

All home-manager module options must use explicit NixOS module types.
Never use `types.anything` where a specific type is known. Overlay
functions access nvfetcher sources via `final.nv-sources.<key>` — never
import `generated.nix` directly. Computed hashes belong in
`hashes.json` sidecars.

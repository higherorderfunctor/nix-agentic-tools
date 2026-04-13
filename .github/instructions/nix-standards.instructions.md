---
applyTo: "**/*.nix"
---

### Nix

All home-manager module options must use explicit NixOS module types.
Never use `types.anything` where a specific type is known. Overlay
packages pin `rev` + `hash` inline in their `.nix` files — never
use external source generators. Dependency hashes (`pnpmDeps`,
`vendorHash`, `cargoHash`) are also inline. Per-platform binary
packages store versions and hashes in a `<name>-sources.json` sidecar
managed by `mkUpdateScript`.

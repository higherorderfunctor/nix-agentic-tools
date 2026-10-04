# Systems this flake builds and caches packages for. flake.nix iterates
# them for every per-system output, and the exported overlay re-exports this
# flake's builds only on these systems (lib/facets/repository.nix).
[
  "aarch64-darwin"
  "x86_64-linux"
]

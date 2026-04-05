# Calls generated.nix with fetchers and merges in sidecar hashes.
# Exposes final.nv-sources.<name> = { pname, version, src, npmDepsHash?, vendorHash? }
_: final: _: let
  generated = import ./.nvfetcher/generated.nix {
    inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
  };
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: attrs:
    attrs // (hashes.${name} or {});
in {
  nv-sources = builtins.mapAttrs merge generated;
}

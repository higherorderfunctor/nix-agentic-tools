# Resolve nvfetcher sources for git tools, merged with sidecar hashes.
#
# Reads from `final.nv-sources` (provided by the top-level
# nv-sources overlay in `flake.nix`) and merges in cargoHash entries
# from this directory's `hashes.json` sidecar — those hashes are
# computed during the first build and pinned, since nvfetcher can't
# produce them itself.
{nv-sources}: let
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: attrs: attrs // (hashes.${name} or {});
in
  builtins.mapAttrs merge nv-sources

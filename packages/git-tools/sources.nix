# Resolve nvfetcher sources for git tools, merged with sidecar hashes.
{
  fetchurl,
  fetchgit,
  fetchFromGitHub,
  dockerTools,
}: let
  generated = import ./.nvfetcher/generated.nix {
    inherit fetchurl fetchgit fetchFromGitHub dockerTools;
  };
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: attrs:
    attrs // (hashes.${name} or {});
in
  builtins.mapAttrs merge generated

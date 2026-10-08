# Equal settings may select different executable builds through runtime package
# overrides. Keep those variants distinct without changing the JSON schema.
{pkgs}: package: config: let
  identity = builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (toString package));
in
  pkgs.writeText "semble-config-${identity}.json" (builtins.toJSON config)

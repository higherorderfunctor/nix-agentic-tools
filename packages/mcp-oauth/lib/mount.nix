# Mount fixed owner data onto isolated, consumer-named instances.
{lib}: let
  options = import ./options.nix {inherit lib;};
in {
  mkOAuthMount = {
    owner,
    profile,
  }: let
    accountName = instance: "${owner}-${instance}";
    module = {config, ...}: {
      options.ai.${owner}.instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.oauth = lib.mkOption {
            type = lib.types.submodule {
              options = options.credentials {scopesDefault = profile.scopes;};
            };
            apply = options.distinctCredentials;
            description = "OAuth credentials and scopes for this instance.";
          };
        });
        default = {};
        apply = options.safeNames;
        description = "Named owner instances.";
      };
      config.ai.mcp-oauth.accounts = lib.mapAttrs' (instance: value:
        lib.nameValuePair (accountName instance) (value.oauth
          // {
            provider = builtins.removeAttrs profile ["name" "scopes"];
            login = {
              inherit instance owner;
              profile = profile.name;
            };
          }))
      (lib.filterAttrs (_: value: value.enable) config.ai.${owner}.instances);
    };
  in {inherit accountName module;};
}

# The existing proxy consumers receive only the generic request-time header.
{lib}: {
  accounts,
  backend,
  stateRoot,
}: let
  normalized = import ./accounts.nix {inherit lib;} {inherit accounts backend stateRoot;};
in
  declaration: let
    inherit (declaration) key optionPath server;
    name = server.proxy.oauthAccount or null;
  in
    if name == null
    then declaration
    else if !(builtins.hasAttr name normalized)
    then throw "${optionPath}.${key}.proxy.oauthAccount: unknown or disabled account '${name}'"
    else
      declaration
      // {
        server =
          server
          // {
            proxy =
              server.proxy
              // {
                # Reuse the generic header type for generated paths too: the
                # backend root is consumer-configurable and becomes Caddy text.
                headers =
                  (lib.evalModules {
                    modules = [
                      ../../../lib/ai/mcpServer/commonSchema.nix
                      {
                        proxy = {
                          inherit (server.proxy) port;
                          headers =
                            server.proxy.headers
                            // {
                              Authorization = {
                                file = "${normalized.${name}.state_dir}/access-token";
                                prefix = "Bearer ";
                              };
                            };
                        };
                      }
                    ];
                  }).config.proxy.headers;
              };
          };
      }

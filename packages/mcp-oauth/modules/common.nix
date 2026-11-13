{
  backend,
  installPackage,
  stateLocation,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ai.mcp-oauth;
  oauthOptions = import ../lib/options.nix {inherit lib;};
  inherit (oauthOptions) scopeType;
  redirectType = lib.types.addCheck lib.types.str (value: let
    parts = builtins.match "http://(localhost|127[.]0[.]0[.]1|[[]::1[]]):([1-9][0-9]{0,4})(/[A-Za-z0-9._~/%-]*)" value;
  in
    parts != null && builtins.fromJSON (builtins.elemAt parts 1) <= 65535);
  accountType = lib.types.submodule {
    options =
      oauthOptions.credentials {}
      // {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable this backend account.";
        };
        login = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              instance = lib.mkOption {type = lib.types.str;};
              owner = lib.mkOption {type = lib.types.str;};
              profile = lib.mkOption {type = lib.types.strMatching "[a-z0-9][a-z0-9_-]*";};
            };
          });
          default = null;
          internal = true;
          description = "Mounted owner login command and instance identity.";
        };
        provider = lib.mkOption {
          type = lib.types.submodule {
            options = {
              authorizeUrl = lib.mkOption {
                type = lib.types.str;
                description = "Authorization endpoint URL.";
              };
              extraScopes = lib.mkOption {
                type = lib.types.listOf scopeType;
                default = [];
                description = "Additional scopes requested during login.";
              };
              loginLifetimeDays = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "Maximum login lifetime in days, or null for no deadline.";
              };
              tokenUrl = lib.mkOption {
                type = lib.types.str;
                description = "Token endpoint URL.";
              };
            };
          };
          description = "Provider data used for authorization and token exchange.";
        };
        redirectUri = lib.mkOption {
          type = redirectType;
          default = "http://localhost:8080/callback";
          description = "Registered HTTP loopback redirect with explicit port and path.";
        };
      };
  };
  accounts = import ../lib/accounts.nix {inherit lib;} {
    inherit (cfg) accounts;
    inherit backend;
    stateRoot = stateLocation config;
  };
  enabled = accounts != {};
  manifest = pkgs.writeText "mcp-oauth-${backend}.json" (builtins.toJSON {inherit accounts backend;});
  # Substitute the output path at build time: the manifest never refers back
  # to this derivation. Reject all long-option abbreviations too, since the
  # Python parser otherwise accepts --man as --manifest.
  mkWrapper = name: arguments:
    import ../../../lib/strict-shell-application.nix pkgs {
      inherit name;
      text = ''
        for argument in "$@"; do
          case "$argument" in
            --help) ;;
            --*) printf '%s\n' 'mcp-oauth: backend options cannot be overridden' >&2; exit 2 ;;
            *) ;;
          esac
        done
        export MCP_OAUTH_WRAPPER=${
          if name == "mcp-oauth"
          then builtins.placeholder "out"
          else wrapper
        }/bin/mcp-oauth
        exec ${config.ai.internal.packages.mcp-oauth}/bin/mcp-oauth --manifest ${manifest} ${arguments} "$@"
      '';
    };
  wrapper = mkWrapper "mcp-oauth" "";
  logins = lib.filter (login: login != null) (map (account: account.login) (builtins.attrValues accounts));
  loginWrappers = lib.unique (map (login:
    mkWrapper "${login.profile}-login" "--owner ${lib.escapeShellArg login.owner} login")
  logins);
in {
  imports = [
    (import ../../ai-module/lib/runtime.nix {
      inherit enabled;
      name = "mcp-oauth";
    })
  ];
  options.ai.mcp-oauth.accounts = lib.mkOption {
    type = lib.types.attrsOf accountType;
    default = {};
    apply = accounts: lib.mapAttrs (_: oauthOptions.distinctCredentials) (oauthOptions.safeNames accounts);
    description = "Backend-local OAuth accounts keyed by safe account ID.";
  };
  config = lib.mkIf enabled (lib.mkMerge [
    (installPackage wrapper)
    (lib.mkIf (loginWrappers != []) (installPackage (pkgs.symlinkJoin {
      name = "mcp-oauth-logins";
      paths = loginWrappers;
    })))
    {
      ai.mcp-oauth = {
        claims.path = map (account: account.state_dir) (builtins.attrValues accounts);
        services = lib.mapAttrs' (name: _:
          lib.nameValuePair "mcp-oauth-${name}" {
            command = ["${wrapper}/bin/mcp-oauth" "daemon" name];
            environment = {
              MCP_OAUTH_CLIENT_ID = cfg.accounts.${name}.clientId;
              MCP_OAUTH_CLIENT_SECRET = cfg.accounts.${name}.clientSecret;
            };
            restart = "on-failure";
          })
        accounts;
      };
    }
  ]);
}

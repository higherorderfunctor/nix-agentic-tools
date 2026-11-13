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
  redact = import ../../../lib/redact {inherit lib;};
  cfg = config.ai.mcp-oauth;
  # Keep rejected credential values out of module-system error rendering.
  credentialType =
    redact.types.redacted
    // {
      merge = loc: defs: let
        value = redact.types.redacted.merge loc defs;
      in
        if redact.isReference value && value._redact ? file
        then value
        else throw "${lib.showOption loc}: requires a credential file reference";
    };
  redirectType = lib.types.addCheck lib.types.str (value: let
    parts = builtins.match "http://(localhost|127[.]0[.]0[.]1|[[]::1[]]):([1-9][0-9]{0,4})(/[A-Za-z0-9._~/%-]*)" value;
  in
    parts != null && builtins.fromJSON (builtins.elemAt parts 1) <= 65535);
  scopeType = lib.types.strMatching "[A-Za-z0-9:._/-]+";
  accountType = lib.types.submodule {
    options = {
      clientId = lib.mkOption {
        type = credentialType;
        description = "File reference for the sops client ID secret.";
      };
      clientSecret = lib.mkOption {
        type = credentialType;
        description = "File reference for the sops client secret.";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable this backend account.";
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
      scopes = lib.mkOption {
        type = lib.types.nonEmptyListOf scopeType;
        description = "Requested account scopes.";
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
  wrapper = import ../../../lib/strict-shell-application.nix pkgs {
    name = "mcp-oauth";
    text = ''
      for argument in "$@"; do
        case "$argument" in
          --help) ;;
          --*) printf '%s\n' 'mcp-oauth: backend options cannot be overridden' >&2; exit 2 ;;
          *) ;;
        esac
      done
      export MCP_OAUTH_WRAPPER=${builtins.placeholder "out"}/bin/mcp-oauth
      exec ${config.ai.internal.packages.mcp-oauth}/bin/mcp-oauth --manifest ${manifest} "$@"
    '';
  };
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
    apply = lib.mapAttrs (name: account:
      if builtins.match "[a-z0-9][a-z0-9_-]*" name == null
      then throw "ai.mcp-oauth.accounts: unsafe account ID"
      else if account.clientId == account.clientSecret
      then throw "ai.mcp-oauth.accounts.${name}: two distinct credential files required"
      else account);
    description = "Backend-local OAuth accounts keyed by safe account ID.";
  };
  config = lib.mkIf enabled (lib.mkMerge [
    (installPackage wrapper)
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

# `ai.airlock.instances.<name>`: airlock gateways, the same on both backends
# apart from the default state root. config.json is rendered at each start
# from `settings`, which mirrors the schema airlock-core parses
# (src/crates/airlock-core/src/config.rs `RawConfig`) field for field, so
# `airlock check-config` referees it (checks/airlock-instances.nix). Client
# tokens and credential files are redact.types.secretFile values: the service
# launcher writes each to a 0600 file and the config holds only its path.
backend: {lib, ...}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) render;
  inherit (lib) mkOption types;
  required = type: description: mkOption {inherit description type;};
  # The ids are map keys and references; airlock-core checks their spelling
  # and that every reference resolves, so they are plain strings here.
  client = types.submodule {
    options = {
      grants = required (types.listOf (types.submodule {
        options = {
          credentials = required (types.listOf types.str) "The `credentials` entries, all for `upstream`, this grant lets the client use.";
          upstream = required types.str "The `upstreams` entry this grant opens.";
        };
      })) "What the client may reach, one grant per upstream.";
      token = required redact.types.secretFile "The token the client presents to the gateway, delivered as a 0600 file.";
    };
  };
  credential = types.submodule {
    options = {
      auth = {
        file = required redact.types.secretFile "The credential, delivered as a 0600 file.";
        type = required (types.enum ["api_key" "oauth_bearer"]) "How the credential is sent upstream.";
      };
      upstream = required types.str "The `upstreams` entry this credential is for.";
    };
  };
  upstream = types.submodule {
    options = {
      intercept = required (types.listOf types.str) "Hosts whose TLS the gateway intercepts to inject this upstream's credentials.";
      provider = required (types.enum ["anthropic"]) "The provider protocol the upstream speaks.";
    };
  };
  settingsType = types.submodule {
    options = {
      clients = mkOption {
        type = types.attrsOf client;
        default = {};
        description = "Clients by id.";
      };
      credentials = mkOption {
        type = types.attrsOf credential;
        default = {};
        description = "Upstream credentials by id.";
      };
      listen = required types.str "The listen address; the instance fixes it to `127.0.0.1:<port>`.";
      stateDir = required (types.strMatching "/.*") "The state directory; the instance fixes it to its `stateDir`.";
      unknownHosts = mkOption {
        type = types.enum ["deny" "tunnel"];
        default = "tunnel";
        description = "What the gateway does with a CONNECT to a host no upstream intercepts.";
      };
      upstreams = mkOption {
        type = types.attrsOf upstream;
        description = "Upstreams by id. `anthropic` is declared by default; another entry adds to it.";
      };
    };
    config.upstreams.anthropic = lib.mkDefault {
      intercept = ["api.anthropic.com"];
      provider = "anthropic";
    };
  };
in {
  imports = [
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      arguments = _: ''serve --config "$AIRLOCK_CONFIG"'';
      inherit backend settingsType;
      defaultPort = 8318;
      derived = {instance, ...}: {
        listen = "127.0.0.1:${toString instance.port}";
        inherit (instance) stateDir;
      };
      owner = "airlock";
      packagePath = "generic.airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.airlock";
      # The three camelCase options take airlock-core's snake_case keys.
      render = settings:
        render {
          prefix = "AIRLOCK";
          settings = {
            clients =
              lib.mapAttrs (_: client: {
                inherit (client) grants;
                token_file = client.token;
              })
              settings.clients;
            inherit (settings) credentials listen upstreams;
            state_dir = settings.stateDir;
            unknown_hosts = settings.unknownHosts;
          };
        };
      tool = "airlock";
      variable = "AIRLOCK_CONFIG";
    })
  ];
}

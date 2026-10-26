# `ai.airlock.instances.<name>`: airlock gateways, the same on both backends
# apart from the default state root. config.json is rendered at each start
# from `settings`, which mirrors the schema airlock-core parses
# (src/crates/airlock-core/src/config.rs `RawConfig`) field for field, so
# `airlock check-config` referees it (checks/airlock-instances.nix). File-backed
# secrets use redact.types.secretFile; managed OAuth has no secret file yet.
backend: {lib, ...}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) render;
  inherit (lib) mkOption types;
  required = type: description: mkOption {inherit description type;};
  # The ids are map keys and references; airlock-core checks their spelling
  # and that every reference resolves, so they are plain strings here.
  client = types.submodule {
    options = {
      grants = required (types.listOf types.str) "Protocol groups this client may use; a grant authorizes every member credential.";
      token = required redact.types.secretFile "The token the client presents to the gateway, delivered as a 0600 file.";
    };
  };
  credential = types.submodule {
    options = {
      accountId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit account identifier for out-of-band Codex quota reads; never inferred from a credential.";
      };
      auth = {
        file = mkOption {
          type = types.nullOr redact.types.secretFile;
          default = null;
          description = "File-backed credential, delivered as a 0600 file; absent for managed OAuth.";
        };
        type = required (types.enum ["api_key" "oauth_bearer" "oauth_managed"]) "Credential mode; managed OAuth is stored by Airlock for the primary client.";
      };
      provider = required types.str "The provider this credential authenticates to.";
    };
  };
  group = types.submodule {
    options = {
      intercept = required (types.listOf types.str) "First-party hosts whose TLS the gateway intercepts for this group.";
      members = required (types.attrsOf (types.submodule {
        options.models = required (types.listOf types.str) "Exact model IDs owned by this credential; the primary owns undeclared IDs.";
      })) "Member credentials and their exact model IDs.";
      primary = required types.str "Member credential whose identity owns non-model traffic and undeclared model IDs.";
      protocol = required (types.enum ["anthropic" "openai"]) "The protocol every member provider must support.";
    };
  };
  provider = types.submodule {
    options = {
      endpoints = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Protocol-keyed HTTPS endpoint overrides; Rust expands the preset once and checks URL shape.";
      };
      preset = mkOption {
        type = types.nullOr (types.enum ["claude" "codex" "zai"]);
        default = null;
        description = "Built-in endpoint preset; a protocol-keyed endpoint overrides its value.";
      };
    };
  };
  settingsType = types.submodule {
    options = {
      authorization = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional inline Cedar policy for CONNECT; null permits within native bounds and an empty string denies all Cedar actions.";
      };
      clients = mkOption {
        type = types.attrsOf client;
        default = {};
        description = "Clients by id.";
      };
      control = mkOption {
        type = types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Whether this instance also serves the read-only loopback control API.";
            };
            port = mkOption {
              type = types.port;
              default = 8401;
              description = "The loopback control port, distinct from the gateway CONNECT port.";
            };
            token = mkOption {
              type = types.nullOr redact.types.secretFile;
              default = null;
              description = "The dedicated control bearer token, delivered as a 0600 file; required when control is enabled.";
            };
          };
        };
        default = {};
        description = "The optional read-only control listener and web API.";
      };
      credentials = mkOption {
        type = types.attrsOf credential;
        default = {};
        description = "Provider credentials by id; ungranted credentials stay unloaded.";
      };
      groups = mkOption {
        type = types.attrsOf group;
        default = {};
        description = "Like-for-like protocol groups by id; ungranted groups stay inert.";
      };
      listen = required types.str "The listen address; the instance fixes it to `127.0.0.1:<port>`.";
      providers = mkOption {
        type = types.attrsOf provider;
        default = {};
        description = "Named providers with preset endpoints and optional protocol overrides.";
      };
      stateDir = required (types.strMatching "/.*") "The state directory; the instance fixes it to its `stateDir`.";
      usage.credentials = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Credentials explicitly authorized for out-of-band quota collection; Codex requires this selection and an accountId.";
      };
      unknownHosts = mkOption {
        type = types.enum ["deny" "tunnel"];
        default = "tunnel";
        description = "What the gateway does with a CONNECT to a host no upstream intercepts.";
      };
    };
  };
in {
  imports = [
    ({config, ...}: {
      config = {
        assertions = lib.concatLists (lib.mapAttrsToList (name: instance: [
            {
              assertion = !instance.settings.control.enable || instance.settings.control.token != null;
              message = "ai.airlock.instances.${name}.settings.control.token is required when control is enabled.";
            }
          ])
          config.ai.airlock.instances);
        ai.airlock.services =
          lib.mapAttrs' (
            name: instance:
              lib.nameValuePair "airlock-${name}" {
                ports.control = lib.mkIf instance.settings.control.enable instance.settings.control.port;
              }
          )
          config.ai.airlock.instances;
      };
    })
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      arguments = instance:
        ''serve --config "$AIRLOCK_CONFIG"''
        + lib.optionalString instance.settings.control.enable
        " --web-root \"${instance.package.frontend}\"";
      inherit backend settingsType;
      claimProxyInstance = true;
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
          settings =
            {
              inherit (settings) authorization;
              clients =
                lib.mapAttrs (_: client: {
                  inherit (client) grants;
                  token_file = client.token;
                })
                settings.clients;
              credentials = lib.mapAttrs (_: credential:
                (lib.optionalAttrs (credential.accountId != null) {account_id = credential.accountId;})
                // {
                  auth = lib.filterAttrs (_: value: value != null) credential.auth;
                  inherit (credential) provider;
                })
              settings.credentials;
              inherit (settings) groups listen;
              providers = lib.mapAttrs (_: provider: lib.filterAttrs (_: value: value != null) provider) settings.providers;
              state_dir = settings.stateDir;
              inherit (settings) usage;
              unknown_hosts = settings.unknownHosts;
            }
            // lib.optionalAttrs settings.control.enable {
              control = {
                listen = "127.0.0.1:${toString settings.control.port}";
                read_token_file = settings.control.token;
              };
            };
        };
      tool = "airlock";
      variable = "AIRLOCK_CONFIG";
    })
  ];
}

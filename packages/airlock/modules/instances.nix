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
      auth = {
        file = mkOption {
          type = types.nullOr redact.types.secretFile;
          default = null;
          description = "File-backed credential, delivered as a 0600 file; absent for managed OAuth.";
        };
        type = required (types.enum ["api_key" "oauth_bearer" "oauth_managed"]) "Credential mode; managed OAuth is accepted by check-config but serve does not support it yet.";
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
        type = types.nullOr (types.enum ["claude" "zai"]);
        default = null;
        description = "Built-in endpoint preset; a protocol-keyed endpoint overrides its value.";
      };
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
      unknownHosts = mkOption {
        type = types.enum ["deny" "tunnel"];
        default = "tunnel";
        description = "What the gateway does with a CONNECT to a host no upstream intercepts.";
      };
    };
  };
in {
  imports = [
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      arguments = _: ''serve --config "$AIRLOCK_CONFIG"'';
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
          settings = {
            clients =
              lib.mapAttrs (_: client: {
                inherit (client) grants;
                token_file = client.token;
              })
              settings.clients;
            credentials = lib.mapAttrs (_: credential:
              credential
              // {
                auth = lib.filterAttrs (_: value: value != null) credential.auth;
              })
            settings.credentials;
            inherit (settings) groups listen;
            providers = lib.mapAttrs (_: provider: lib.filterAttrs (_: value: value != null) provider) settings.providers;
            state_dir = settings.stateDir;
            unknown_hosts = settings.unknownHosts;
          };
        };
      tool = "airlock";
      variable = "AIRLOCK_CONFIG";
    })
  ];
}

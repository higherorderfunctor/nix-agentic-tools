# The committed packages/cliproxyapi/extracted/ and what reads it:
#
#   cliproxyapi-extracted         drift: the sidecar equals a fresh extraction
#                                 of the pinned source, and every hand row in
#                                 ../extract/annotations.json still names an
#                                 extracted path.
#   cliproxyapi-config-validates  configurations rendered from the typed
#                                 options pass CLIProxyAPI's own checks. One
#                                 setting every typed path passes
#                                 ValidateV8Config only: its placeholder
#                                 strings are no valid CIDR or URL, which
#                                 LoadConfig checks. One shaped like a real
#                                 instance is completed at run time by
#                                 ../lib/config.jq, as the ai.proxy start
#                                 script completes it (file secrets, client
#                                 key, auth dir), and passes both
#                                 ValidateV8Config and LoadConfig, the loader
#                                 the service runs.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  cliproxyapi = import ../lib/extracted.nix {inherit lib;};
  credentials = import ../../../lib/credentials.nix {inherit lib;};
  inherit (cliproxyapi.tree) fieldsAt nodes;

  # A value for every typed path below `path`. `any` paths are left unset:
  # their own decoders, not the tree, say what they accept.
  sampleAt = path: let
    node = nodes.${path};
  in
    if node ? secret
    then {plain = "sample";}
    else if node ? enum
    then builtins.head node.enum
    else
      {
        any = null;
        bool = true;
        duration = "1s";
        int = 1;
        list = [(sampleAt "${path}[]")];
        map.sample = sampleAt "${path}.<name>";
        number = 1;
        object = lib.mapAttrs (_: sampleAt) (fieldsAt path);
        string = "sample";
      }
      .${
        node.type
      };

  samples = {
    every-path =
      lib.mapAttrs (_: sampleAt) (fieldsAt "")
      # Catalog sources must be URLs or absolute paths (ModelCatalogs.Validate).
      // {models = lib.mapAttrs (_: _: "/sample") (fieldsAt "models");};
    instance = {
      api-keys.claude = [
        {
          base-url = "https://api.anthropic.com";
          headers.Authorization.file = "${pkgs.writeText "sample-header" "Bearer sk-ant-sample"}";
          keys = [
            {
              api-key.file = "${pkgs.writeText "sample-key" "sk-ant-file"}";
              proxy-url.plain = "http://127.0.0.1:3128";
            }
            {
              api-key.plain = "sk-ant-other";
              priority = 2;
            }
          ];
          name = "anthropic";
          priority = 1;
        }
      ];
      oauth.model-alias.claude = [
        {
          alias = "sonnet";
          name = "claude-sonnet-4-6";
        }
      ];
      requests.proxy-url.file = "${pkgs.writeText "sample-proxy" "socks5://user:pass@127.0.0.1:1080"}";
      routing.strategy = "fill-first";
      server = {
        host = "127.0.0.1";
        port = 8317;
      };
    };
  };
  render = settings:
    cliproxyapi.render
    (lib.evalModules {
      modules = [
        {
          options.settings = lib.mkOption {type = cliproxyapi.settingsType {jsonType = (pkgs.formats.json {}).type;};};
          config = {inherit settings;};
        }
      ];
    })
    .config
    .settings;
  rendered = name: settings: pkgs.writeText "${name}.json" (builtins.toJSON (render settings).value);
  # `rendered`, then the start script's run-time step: each file secret
  # read into its variable, then ../lib/config.jq.
  completed = name: settings: let
    secrets = lib.imap0 (index: entry: entry // {var = "SECRET_${toString index}";}) (render settings).secrets;
  in
    pkgs.runCommand "${name}.json" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatMapStringsSep "\n" (entry: credentials.mkSecretExport pkgs entry.var entry.secret) secrets}
      CPA_CLIENT_KEY=sample-client-key ${lib.getExe pkgs.jq} \
        --arg authDir /var/empty/ai-proxy/auth \
        --argjson secrets ${lib.escapeShellArg (builtins.toJSON (map (entry: {inherit (entry) path var;}) secrets))} \
        --from-file ${cliproxyapi.configFilter} \
        ${rendered name settings} >"$out"
    '';
  sampleDir = name: files:
    pkgs.linkFarm name (lib.mapAttrsToList (name: path: {
        name = "${name}.json";
        inherit path;
      })
      files);
in {
  checks =
    (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "cliproxyapi";
      inherit package;
      results = import ../extract/rules.nix {inherit lib;};
    }
    // {
      cliproxyapi-config-validates = (import ../extract {inherit pkgs;} package).validate "cliproxyapi-config-validates" {
        load = sampleDir "cliproxyapi-config-loads" {instance = completed "instance" samples.instance;};
        validate = sampleDir "cliproxyapi-config-samples" {
          every-path = rendered "every-path" samples.every-path;
          instance = completed "instance" samples.instance;
        };
      };
    };
}

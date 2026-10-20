# The generated settings type, its render and CLIProxyAPI's own loader agree:
# a sample that sets every leaf, rendered with each secret placeholder
# replaced as a launcher replaces it (the value JSON-encoded), loads through
# internal/config's LoadConfig.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) fill;
  # Values LoadConfig validates beyond their node type, each with the file in
  # internal/ that refuses the sample's generic value:
  overrides = {
    # refinements: the values they admit
    config-version = 8;
    # config/sdk_config.go: a Go duration or integer seconds
    "client.codex.web-search-result-cache.ttl" = "1s";
    # config/credential_in_flight.go: stale-after at least three snapshot
    # intervals, part bytes at least 1024, revision bytes at least one part
    "credentials.in-flight.max-part-bytes" = 1024;
    "credentials.in-flight.max-revision-bytes" = 1024;
    "credentials.in-flight.snapshot-interval" = "1s";
    "credentials.in-flight.stale-after" = "3s";
    "credentials.in-flight.staging-retention" = "1s";
    # registry/catalog_config.go: an http(s) URL or an absolute path
    "models.catalog" = "/catalog.json";
    "models.codex-catalog" = "/catalog.json";
    "models.devin-catalog" = "/catalog.json";
    # config/disable_image_generation_mode.go: the custom decoder accepts off
    "multimedia.disable-image-generation" = "off";
    # config/codex_live.go: an IP, two UDP ports per session, STUN/TURN URLs
    "oauth.providers.codex.live-media-relay.ice-servers[].urls[]" = "stun:127.0.0.1";
    "oauth.providers.codex.live-media-relay.public-ip" = "127.0.0.1";
    "oauth.providers.codex.live-media-relay.udp-port-max" = 2;
    # config/config_validation.go: raw params must contain valid JSON text
    "requests.payload.default-raw[].params.<name>" = "{}";
    "requests.payload.override-raw[].params.<name>" = "{}";
    # config/trusted_proxies.go: an IP or CIDR
    "server.trusted-proxies[]" = "127.0.0.1";
    # config/config_normalization.go: supported client-request-id mode
    "upstream.claude.header-defaults.client-request-id" = "on";
  };
  typed =
    (lib.evalModules {
      modules = [
        {
          options.settings = lib.mkOption {type = cliproxyapi.settingsType;};
          config.settings = cliproxyapi.sample {inherit overrides;};
        }
      ];
    })
    .config
    .settings;
  rendered = cliproxyapi.render typed;
  # YAML-significant characters and a literal placeholder survive substitution
  # and the native loader's writable-file rewrite.
  dummy = name:
    if name == "CLIPROXYAPI_REQUESTS_PROXY_URL"
    then "{$CLIPROXYAPI_LITERAL}: # ' \" \\ !tag [x] {y}\nnext"
    else "dummy\"'\\-${name}";
in {
  checks.cliproxyapi-settings = (extractedLib {inherit pkgs;}).goTest {
    env.NAT_PROXY_URL = dummy "CLIPROXYAPI_REQUESTS_PROXY_URL";
    sources = {
      "nat_config.yaml" = pkgs.writeText "cliproxyapi-settings-sample.yaml" (fill (lib.mapAttrs (name: _: dummy name) rendered.secrets) rendered.content);
      "nat_load_test.go" = ./settings_test.go;
    };
    name = "cliproxyapi-settings";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
    packagePath = "internal/config";
    postTest = ''echo "ok — CLIProxyAPI loads the rendered settings sample" >"$out"'';
    run = "TestNatLoad";
  };
}

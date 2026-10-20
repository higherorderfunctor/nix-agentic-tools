# Typed CLIProxyAPI settings from the drift-checked config facts, through
# lib/extracted/options.nix, and their render through lib/extracted/render.nix.
# The facts are read as the committed file; never pass the package's
# `passthru.extracted` here, which is import-from-derivation.
{lib, ...}: let
  refinements = let
    # Durations are strings CLIProxyAPI parses with time.ParseDuration at
    # load, refusing the config when one fails: credentials.in-flight's in
    # internal/config/credential_in_flight.go (Durations), and the Codex web
    # search result cache TTL in internal/config/sdk_config.go (Validate,
    # which also takes integer seconds; the type admits the duration form).
    duration = {
      type = "string";
      refine = {types, ...}: types.duration;
    };
  in {
    "client.codex.web-search-result-cache.ttl" = duration;
    # The v8 loader refuses any other value (internal/config/config_v8.go,
    # flattenV8: "unsupported config-version (expected 8)").
    config-version = {
      type = "int";
      refine = {types, ...}: types.enum [8];
    };
    "credentials.in-flight.snapshot-interval" = duration;
    "credentials.in-flight.stale-after" = duration;
    "credentials.in-flight.staging-retention" = duration;
  };
  generated = import ../../../lib/extracted/options.nix {inherit lib;} {
    inherit refinements;
    nodes = (import ../extract/rules.nix {inherit lib;}).config.entries;
    tool = "CLIProxyAPI";
  };
in {
  cliproxyapi = {
    inherit refinements;
    inherit (generated) report sample;
    # settings → { content; secrets; }: config.yaml as JSON text, each secret
    # a `{$CLIPROXYAPI_<PATH>}` placeholder.
    render = settings:
      (import ../../../lib/extracted/render.nix {inherit lib;}).render {
        prefix = "CLIPROXYAPI";
        inherit settings;
      };
    settingsType = generated.type;
  };
}

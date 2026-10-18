# Typed CLIProxyAPI settings from the drift-checked config facts, through
# lib/extracted/options.nix, and their render through lib/extracted/render.nix.
# The facts are read as the committed file; never pass the package's
# `passthru.extracted` here, which is import-from-derivation.
{lib, ...}: let
  refinements = let
    # credentials.in-flight's durations are strings CLIProxyAPI parses with
    # time.ParseDuration at load, refusing the config when one fails
    # (internal/config/credential_in_flight.go, Durations).
    duration = {
      type = "string";
      refine = {types, ...}: types.duration;
    };
  in {
    # The v8 loader refuses any other value (internal/config/config_v8.go,
    # flattenV8: "unsupported config-version (expected 8)").
    config-version = {
      type = "int";
      refine = {types, ...}: types.enum [8];
    };
    "credentials.in-flight.snapshot-interval" = duration;
    "credentials.in-flight.stale-after" = duration;
    "credentials.in-flight.staging-retention" = duration;
    # A bool, or one of two modes (internal/config/
    # disable_image_generation_mode.go: "allowed: true, false, chat,
    # passthrough").
    "multimedia.disable-image-generation" = {
      type = "any";
      refine = {types, ...}: types.either types.bool (types.enum ["chat" "passthrough"]);
    };
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

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
    # CPA reads an absent or empty list in a rule as "no restriction on this
    # dimension" (sdk/cliproxy/auth/key_allowlist.go: len(rule.IDs) == 0,
    # len(rule.BaseURLs) == 0), so a list meant to narrow a rule that comes
    # out empty would grant every credential of the provider and kind. The
    # generated element type refuses null too: render drops null elements,
    # which turns [null] into [] (lib/extracted/render.nix). This type checks
    # the definitions; a list of only `mkIf false` elements merges to [] past
    # it, so the module also asserts on the merged value
    # (modules/instances.nix). Leave the option unset to leave a dimension
    # unrestricted.
    narrowing = {
      type = "list";
      refine = {
        elementType,
        types,
        ...
      }:
        types.nonEmptyListOf elementType
        // {description = "non-empty list of strings (an empty list would lift the restriction)";};
    };
  in {
    "access.key-allowlist[].credentials[].base-urls" = narrowing;
    "access.key-allowlist[].credentials[].ids" = narrowing;
    # The allowlist patch matches a rule only when its kind normalizes to a
    # credential kind (sdk/cliproxy/auth/key_allowlist.go, through
    # normalizeAuthKind in classification.go); any other value allows nothing.
    "access.key-allowlist[].credentials[].kind" = {
      type = "string";
      refine = {types, ...}: types.enum ["apikey" "oauth"];
    };
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
  subOptions = type: type.getSubOptions [];
in {
  cliproxyapi = {
    # `access.key-allowlist[].credentials`'s own type, so a rule written
    # elsewhere (`ai.<runtime>.proxy.allow`) is checked where it is written.
    keyAllowlistCredentialsType = (subOptions (subOptions (subOptions generated.type).access.type).key-allowlist.type).credentials.type;
    # Named upstream API-key providers (./providers.nix).
    providers = import ./providers.nix {inherit lib;};
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

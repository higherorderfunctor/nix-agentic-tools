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
    # CPA caps positive scheduler weights at one million.
    "oauth.credential-overrides[].weight" = {
      type = "int";
      refine = {types, ...}: types.addCheck types.int (value: value <= 1000000);
    };
  };
  nodes = (import ../extract/rules.nix {inherit lib;}).config.entries;
  generated = import ../../../lib/extracted/options.nix {inherit lib;} {
    inherit refinements;
    inherit nodes;
    tool = "CLIProxyAPI";
  };
in {
  cliproxyapi = {
    # Named upstream API-key providers (./providers.nix).
    providers = import ./providers.nix {
      inherit lib;
      oauthOptions =
        (import ../../../lib/extracted/options.nix {inherit lib;} {
          nodes =
            lib.mapAttrs' (path: value: lib.nameValuePair (lib.removePrefix "oauth.credential-overrides[]." path) value)
            (lib.filterAttrs (path: _: lib.hasPrefix "oauth.credential-overrides[]." path && !(lib.elem path ["oauth.credential-overrides[].account" "oauth.credential-overrides[].provider"])) nodes);
          refinements.weight = refinements."oauth.credential-overrides[].weight";
          tool = "CLIProxyAPI OAuth credentials";
        }).options;
    };
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

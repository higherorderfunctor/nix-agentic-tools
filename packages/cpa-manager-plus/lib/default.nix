# Typed CPA Manager Plus settings from the drift-checked config.json and
# environment facts, through lib/extracted/options.nix: one tree whose
# `config` is config.json and whose `environment` is the variables Manager
# Plus reads. Its keys are environment variables natively, so `render` lifts
# no secret out of config.json; the key-carrying variables take redact
# references and pass through as the service's environment.
{lib, ...}: let
  results = import ../extract/rules.nix {inherit lib;};
  prefixed = surface: lib.mapAttrs' (path: node: lib.nameValuePair "${surface}.${path}" node) results.${surface}.entries;
  exclusions = {
    "environment.CPA_MANAGER_CONFIG" = "the launcher points it at the rendered config.json";
  };
  generated = import ../../../lib/extracted/options.nix {inherit lib;} {
    inherit exclusions;
    nodes =
      prefixed "config"
      // prefixed "environment"
      // {
        config = {
          description = "config.json, which the environment overrides.";
          type = "object";
        };
        environment = {
          description = "Environment variables, which take precedence over config.json.";
          type = "object";
        };
      };
    tool = "CPA Manager Plus";
    # How a variable is parsed and the config.json keys it overrides: prose
    # the type does not carry.
    unread = ["configKeys" "readBy"];
  };
  orEmpty = value:
    if value == null
    then {}
    else value;
in {
  cpa-manager-plus = {
    inherit exclusions;
    inherit (generated) report sample;
    # settings → { content; secrets; environment; }: config.json as JSON text,
    # and the set variables, for a redact.types.environment option.
    render = settings:
      (import ../../../lib/extracted/render.nix {inherit lib;}).render {
        prefix = "CPA_MANAGER_PLUS";
        settings = orEmpty settings.config;
      }
      // {environment = lib.filterAttrs (_: value: value != null) (orEmpty settings.environment);};
    settingsType = generated.type;
  };
}

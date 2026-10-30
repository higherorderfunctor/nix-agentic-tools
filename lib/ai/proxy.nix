# Network egress has the same meaning for every runtime; only delivery differs.
{lib}: let
  peers = {
    http = "https";
    https = "http";
  };
  fields = builtins.attrNames peers;
  protocolOptions = lib.mapAttrs (field: _:
    lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Network proxy for ${lib.toUpper field} traffic, delivered as `${lib.toUpper field}_PROXY`; null suppresses generated delivery. Native values win.";
    })
  peers;
  selected = registry: selection:
    if selection.instance == null
    then {}
    else registry.${selection.instance} or {};
in {
  inherit fields;
  assertionsFor = registry: path: selection: let
    entry = selected registry selection;
    registered = lib.concatStringsSep ", " (builtins.attrNames registry);
  in
    lib.optional (selection.instance != null && !(entry.enable or false)) {
      assertion = false;
      message = "${lib.showOption path}.instance names `${selection.instance}`, which is ${
        if entry == {}
        then "not registered"
        else "disabled"
      }; registered instances: ${registered}.";
    };
  # Copy the selector separately. Instance-derived protocols stay at option
  # default priority and follow the runtime's selected instance, including null.
  # Copy explicit root fields. Copy their sibling fallback only where the
  # runtime's selected instance offers no origin. Copying instance-derived
  # values would pin the root instance even when the runtime selects another.
  copyDown = registry: root: options: runtime:
    {instance = lib.mkIf (options.instance.highestPrio < 1500) (lib.mkDefault root.instance);}
    // lib.mapAttrs (field: peer:
      lib.mkIf
      (options.${field}.highestPrio
        < 1500
        || ((selected registry runtime).${field} or null)
        == null
        && options.${peer}.highestPrio < 1500)
      (lib.mkDefault (
        if options.${field}.highestPrio < 1500
        then root.${field}
        else root.${peer}
      )))
    peers;
  environment = proxy:
    lib.mapAttrs' (field: value: lib.nameValuePair "${lib.toUpper field}_PROXY" value)
    (lib.filterAttrs (_: value: value != null) proxy);
  # Plain option trees retain leaf priorities. Only an explicitly defined peer
  # can supply a sibling default; an instance's HTTPS origin never creates HTTP.
  options = registry: config: options:
    (lib.mapAttrs (field: peer:
      protocolOptions.${field}
      // {
        default =
          if ((selected registry config).${field} or null) != null
          then (selected registry config).${field}
          else if options.${peer}.highestPrio < 1500
          then config.${peer}
          else null;
        defaultText = lib.literalExpression "the selected instance's ${field} origin, otherwise the explicitly defined ${peer} value or null";
        description = ''
          Network proxy for ${lib.toUpper field} traffic, delivered as
          `${lib.toUpper field}_PROXY`. An undefined field defaults to the
          selected instance's origin for that protocol, then to an explicitly
          defined sibling when the instance does not offer that protocol.
          Explicit null suppresses this variable's generated default.
          Runtime values override root defaults field by field; native values
          win. Claude uses settings `env`; Codex, Kimchi and Kiro v3 use
          launcher environment defaults. Kiro v2 and github.com Copilot warn
          because delivery is unsupported.
        '';
      })
    peers)
    // {
      instance = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Network proxy instance registered by an owner. Its protocol origins supply defaults; explicit protocol values, including null, win. Runtime values override root defaults field by field.";
      };
    };
  registryOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options =
        (lib.mapAttrs (field: option:
          option
          // {description = "Instance origin for ${lib.toUpper field} traffic; null means this instance does not offer that protocol, so an explicit sibling may still supply its fallback.";})
        protocolOptions)
        // {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the instance runs; selecting a disabled instance fails evaluation.";
          };
        };
    });
    default = {};
    internal = true;
    visible = false;
    description = "Network proxy instances registered by owners, who claim each name in `ai.claims.proxy-instance`. Separate from inference instances.";
  };
  resolvedType = lib.types.submodule {options = protocolOptions;};
}

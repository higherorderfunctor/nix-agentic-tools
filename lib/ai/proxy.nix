# Network egress has the same meaning for every runtime; only delivery differs.
{lib}: let
  lookup = registry: option: name: let
    entry = registry.${name} or null;
    registered = lib.concatStringsSep ", " (builtins.attrNames registry);
    refusal = status: {problem = "${option} names `${name}`, which is ${status}; registered instances: ${registered}.";};
  in
    if entry == null
    then refusal "not registered"
    else if !entry.enable
    then refusal "disabled"
    else {inherit entry;};
  peers = {
    http = "https";
    https = "http";
  };
  fields = builtins.attrNames peers;
  protocolOptions = lib.mapAttrs (_: _:
    lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
    })
  peers;
  selected = registry: selection:
    if selection.instance == null
    then {}
    else registry.${selection.instance} or {};
in {
  inherit fields;
  assertionsFor = registry: path: selection: let
    found = lookup registry "${lib.showOption path}.instance" selection.instance;
  in
    lib.optional (selection.instance != null && found ? problem) {
      assertion = false;
      message = found.problem;
    };
  copyDown = registry: root: options: runtime:
    {instance = lib.mkIf (options.instance.highestPrio < 1500) (lib.mkDefault root.instance);}
    // lib.mapAttrs (field: peer: let
      explicit = options.${field}.highestPrio < 1500;
      peerFallback = ((selected registry runtime).${field} or null) == null && options.${peer}.highestPrio < 1500;
    in
      lib.mkIf (explicit || peerFallback) (lib.mkDefault (
        if explicit
        then root.${field}
        else root.${peer}
      )))
    peers;
  environment = proxy: instance:
    lib.mapAttrs' (field: value: lib.nameValuePair "${lib.toUpper field}_PROXY" value)
    (lib.filterAttrs (_: value: value != null) proxy)
    // lib.optionalAttrs (instance != null && (proxy.http != null || proxy.https != null)) {NO_PROXY = "127.0.0.1,localhost,::1";};
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
          `${lib.toUpper field}_PROXY`. See
          [Network Proxy](https://github.com/higherorderfunctor/nix-agentic-tools/blob/main/dev/fragments/ai-proxy/ai-proxy.md)
          for instance selection, defaults and runtime delivery.
        '';
      })
    peers)
    // {
      instance = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Network proxy instance registered by an owner. See the Network Proxy documentation for selection and default precedence.";
      };
    };
  registryOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options =
        (lib.mapAttrs (field: _:
          lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Instance origin for ${lib.toUpper field} traffic.";
          })
        peers)
        // {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the instance runs; selecting a disabled instance fails evaluation.";
          };
          trust = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = "For a TLS-intercepting instance: an executable printing the path of its PEM trust bundle, appending its CA to the optional inherited bundle argument. It fails if the instance CA is unavailable. Its optional passthru.jailPermissions function contributes jail.nix permissions when the selected runtime is jailed.";
          };
        };
    });
    default = {};
    internal = true;
    visible = false;
    description = "Network proxy instances registered by owners, who claim each name in `ai.claims.proxy-instance`. Separate from inference instances.";
  };
  # Trust follows an effective protocol origin, not a selector whose protocols
  # were overridden or opted out. The runtime may also replace normalized values.
  resolveTrust = registry: selection: protocols: let
    entry = selected registry selection;
  in
    if lib.any (field: protocols.${field} != null && protocols.${field} == (entry.${field} or null)) fields
    then entry.trust or null
    else null;
  resolvedType = lib.types.submodule {options = protocolOptions;};
}

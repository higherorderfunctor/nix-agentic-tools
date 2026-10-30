# Network egress has the same meaning for every runtime; only delivery differs.
{lib}: let
  peers = {
    http = "https";
    https = "http";
  };
in {
  environment = proxy:
    lib.mapAttrs' (field: value: lib.nameValuePair "${lib.toUpper field}_PROXY" value)
    (lib.filterAttrs (_: value: value != null) proxy);
  fields = builtins.attrNames peers;
  # Plain option trees keep each leaf's definition priority visible to the
  # root-to-runtime copy. A default reads only an explicitly defined peer:
  # two absent fields therefore cannot chase each other's defaults.
  options = config: options:
    lib.mapAttrs (field: peer:
      lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default =
          if options.${peer}.highestPrio < 1500
          then config.${peer}
          else null;
        defaultText = lib.literalExpression "the explicitly defined ${peer} value, otherwise null";
        description = ''
          Network proxy for ${lib.toUpper field} traffic, delivered as
          `${lib.toUpper field}_PROXY`. When only one protocol is defined,
          the other defaults to it. Explicit null suppresses this variable's
          generated default. Runtime values override root defaults field by
          field; native values win. Claude uses settings `env`; Codex, Kimchi
          and Kiro v3 use launcher environment defaults. Kiro v2 and github.com
          Copilot warn because delivery is unsupported.
        '';
      })
    peers;
}

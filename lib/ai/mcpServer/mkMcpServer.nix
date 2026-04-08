# Generic factory for MCP server factory-of-factories.
#
# Outer call: { name, defaults, options ? {} }
#   - name:     identifier for the server (used in module labels / errors)
#   - defaults: attrs that prefill commonSchema fields (package, type,
#               command, args, env, settings, url) and any custom options
#   - options:  optional extra option declarations layered on top of
#               commonSchema (consumer-defined per-server fields)
#
# Returns: consumerArgs → typedAttrset
#   The returned function takes a consumer override attrset, evaluates
#   the merged module tree (commonSchema + custom options + defaults +
#   consumerArgs), and yields the final config attrset.
{lib}: {
  name,
  defaults,
  options ? {},
}: consumerArgs: let
  commonSchema = import ./commonSchema.nix;
  evaluated = lib.evalModules {
    modules = [
      commonSchema
      {inherit options;}
      {
        # `name` is captured purely for diagnostics (e.g. error messages
        # via `_module.args` in evalModules failures). It is intentionally
        # NOT placed under `config` to avoid colliding with caller-defined
        # options.
        _module.args.mcpServerName = name;
      }
      {config = defaults;}
      {config = consumerArgs;}
    ];
  };
in
  evaluated.config

# The env-var spelling for a secret a launcher or proxy exports: upper-case,
# every non-alphanumeric becomes '_'. The MCP proxy and the Kiro secret
# preprocessor both name variables this way, so they share this one copy.
{lib}: let
  sanitize = s:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper s)));
in {
  # envVarName "MCP_PROXY" "my-server" "token" == "MCP_PROXY_MY_SERVER_TOKEN"
  envVarName = prefix: serverName: field: "${prefix}_${sanitize serverName}_${sanitize field}";
}

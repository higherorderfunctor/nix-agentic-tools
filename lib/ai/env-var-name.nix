# The env-var spelling for a value a launcher or proxy exports: upper-case,
# every non-alphanumeric becomes '_'. The MCP proxy, the Kiro secret
# preprocessor and the extracted-settings renderer all name variables this
# way, so they share this one copy.
{lib}: let
  sanitize = segment:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper (toString segment))));
in {
  inherit sanitize;
  # envVarName "MCP_PROXY" "my-server" "token" == "MCP_PROXY_MY_SERVER_TOKEN"
  envVarName = prefix: serverName: field: "${prefix}_${sanitize serverName}_${sanitize field}";
}

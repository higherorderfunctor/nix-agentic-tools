# Kiro expands header placeholders at launch, but URL placeholders only at
# activation. Keep their redact bindings separate so envsubst touches URLs only.
{lib}: let
  inherit (lib) foldl' mapAttrs;

  sanitize = s:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper s)));
  deriveEnvVar = serverName: fieldName: "KIRO_MCP_${sanitize serverName}_${sanitize fieldName}";

  mergeEnvs = maps:
    foldl' (acc: env:
      foldl' (a: name:
        if a ? ${name} && a.${name} != env.${name}
        then throw "kiro mcp secrets: derived variable '${name}' names different sources; rename the server or header."
        else a // {${name} = env.${name};})
      acc (builtins.attrNames env))
    {}
    maps;

  renderValue = serverName: fieldName: mkPlaceholder: value:
    if builtins.isString value
    then {
      rendered = value;
      env = {};
    }
    else let
      var = deriveEnvVar serverName fieldName;
    in {
      rendered = mkPlaceholder var;
      env = {${var} = value;};
    };

  processServer = serverName: server: let
    headers = server.headers or {};
    url = server.url or null;
    headerResults = mapAttrs (headerName:
      renderValue serverName "header_${headerName}" (var: "\${env:${var}}"))
    headers;
    urlResult =
      if url == null
      then null
      else renderValue serverName "url" (var: "\${${var}}") url;
  in {
    server =
      server
      // lib.optionalAttrs (headers != {}) {headers = mapAttrs (_: r: r.rendered) headerResults;}
      // lib.optionalAttrs (urlResult != null) {url = urlResult.rendered;};
    secretEnv = mergeEnvs (map (r: r.env) (builtins.attrValues headerResults));
    urlSecretEnv =
      if urlResult == null
      then {}
      else urlResult.env;
  };

  renderKiroSecrets = servers: let
    processed = mapAttrs processServer servers;
    secretEnv = mergeEnvs (map (p: p.secretEnv) (builtins.attrValues processed));
    urlSecretEnv = mergeEnvs (map (p: p.urlSecretEnv) (builtins.attrValues processed));
    overlap = builtins.filter (n: urlSecretEnv ? ${n}) (builtins.attrNames secretEnv);
  in
    assert lib.assertMsg (overlap == []) "kiro mcp secrets: derived variables name both a header and URL; rename the server or header."; {
      servers = mapAttrs (_: p: p.server) processed;
      inherit secretEnv urlSecretEnv;
    };
in {
  inherit deriveEnvVar renderKiroSecrets;
}

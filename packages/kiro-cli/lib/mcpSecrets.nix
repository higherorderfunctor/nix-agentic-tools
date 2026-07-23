# Kiro-local preprocessing for SOPS-injectable MCP http headers.
#
# Kiro (verified against 2.13.0) substitutes `${env:VAR}` in http header
# VALUES at launch. So a credential-valued header — an attrset
# { file|helper; prefix?; suffix?; var?; }, see
# lib/ai/mcpServer/secretValue.nix — is rendered into mcp.json as a
# `<prefix>${env:VAR}<suffix>` placeholder, and the SAME VAR is exported
# into the kiro launcher's environment from the secret file at runtime
# (never baked into the store). Placeholder and export are derived from
# ONE `deriveEnvVar`, so they always match.
#
# `url` is NOT processed here — Kiro does not env-substitute the url field.
{lib}: let
  inherit (lib) foldl' mapAttrs;

  # Deterministic default env-var name from server + header name.
  # The result is upper case; every non-alphanumeric character becomes '_'.
  sanitize = s:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper s)));
  deriveEnvVar = serverName: headerName: "KIRO_MCP_${sanitize serverName}_${sanitize headerName}";

  isCredential = v: builtins.isAttrs v && (v ? file || v ? helper);

  # Process one server → { server; secretEnv; }. Non-http servers (no
  # `headers`) pass through untouched.
  processServer = serverName: server: let
    headers = server.headers or {};
    processHeader = headerName: hv:
      if !(isCredential hv)
      then {
        rendered = hv;
        env = {};
      }
      else let
        hasFile = (hv.file or null) != null;
        hasHelper = (hv.helper or null) != null;
        var =
          if (hv.var or null) != null
          then hv.var
          else deriveEnvVar serverName headerName;
        prefix = hv.prefix or "";
        suffix = hv.suffix or "";
        cred =
          if hasFile
          then {inherit (hv) file;}
          else {inherit (hv) helper;};
      in
        assert lib.assertMsg (hasFile || hasHelper) "kiro mcp secrets: header '${headerName}' on server '${serverName}' sets neither `file` nor `helper` — a credential needs exactly one.";
        assert lib.assertMsg (!(hasFile && hasHelper)) "kiro mcp secrets: header '${headerName}' on server '${serverName}' sets both `file` and `helper` — set exactly one."; {
          rendered = "${prefix}\${env:${var}}${suffix}";
          env = {${var} = cred;};
        };
    processed = mapAttrs processHeader headers;
  in {
    server =
      if headers == {}
      then server
      else server // {headers = mapAttrs (_: p: p.rendered) processed;};
    secretEnv =
      foldl' (acc: p: acc // p.env) {} (builtins.attrValues processed);
  };

  renderKiroSecrets = servers: let
    processed = mapAttrs processServer servers;
    # Merge per-server secretEnv; a VAR bound to two DIFFERENT sources is
    # a collision (silent last-wins would export the wrong secret).
    mergeEnv = acc: p:
      foldl' (a: name:
        if (a ? ${name}) && (a.${name} != p.secretEnv.${name})
        then throw "kiro mcp secrets: env var '${name}' is bound to two different secret sources — give one an explicit distinct `var`."
        else a // {${name} = p.secretEnv.${name};})
      acc (builtins.attrNames p.secretEnv);
  in {
    servers = mapAttrs (_: p: p.server) processed;
    secretEnv = foldl' mergeEnv {} (builtins.attrValues processed);
  };
in {
  inherit deriveEnvVar renderKiroSecrets;
}

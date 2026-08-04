# Kiro-local preprocessing for SOPS-injectable MCP http headers AND url.
#
# Kiro (verified against 2.13.0) substitutes `${env:VAR}` in http header
# VALUES at launch, but NOT in the url field. So a credential value — an
# attrset { file|helper; prefix?; suffix?; var?; }, see
# lib/ai/mcpServer/secretValue.nix — is handled per field:
#
#   * A credential HEADER renders into mcp.json as a
#     `<prefix>${env:VAR}<suffix>` placeholder; the SAME VAR is exported
#     into the kiro launcher's environment from the secret at runtime
#     (collected in `secretEnv`), and Kiro substitutes it at launch.
#   * A credential URL renders into the store TEMPLATE as a bare
#     `<prefix>${VAR}<suffix>` sentinel; because Kiro will not expand it,
#     WE substitute it at activation with `envsubst` from the decrypted
#     secret (collected in `urlSecretEnv`), writing a real private
#     mcp.json. See `mkMcpJsonScript` / `ai.kiro.mcpWriteMode`.
#
# Placeholder and export are derived from ONE `deriveEnvVar`, so they
# always match. The two var maps are kept SEPARATE — they are injected
# by different mechanisms at different times (launcher env vs activation
# envsubst) — and required DISJOINT.
{lib}: let
  inherit (lib) foldl' mapAttrs;

  # Deterministic default env-var name from server + field name.
  # The result is upper case; every non-alphanumeric character becomes '_'.
  sanitize = s:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper s)));
  deriveEnvVar = serverName: fieldName: "KIRO_MCP_${sanitize serverName}_${sanitize fieldName}";

  # A DERIVED name is safe by construction (`sanitize` above), but an
  # explicit `var` is user-supplied and reaches generated shell verbatim:
  # `export <var>=…` in the activation writer and `${<var>}` in the
  # envsubst list. An illegal identifier there produces a BROKEN activation
  # script — a confusing runtime shell error, at the one moment secrets are
  # being materialized — instead of a config error. Reject it at eval, where
  # the message can name the option. POSIX portable-name charset; a leading
  # digit is invalid.
  isShellName = v: builtins.match "[A-Za-z_][A-Za-z0-9_]*" v != null;

  isCredential = v: builtins.isAttrs v && (v ? file || v ? helper);

  # Render one secretValue. A plain string passes through untouched. A
  # credential renders to `<prefix><placeholder><suffix>` and yields a
  # `{ VAR = cred; }` env entry. `mkPlaceholder var` produces the
  # substitution token — Kiro's `${env:VAR}` for a header (Kiro expands
  # it at launch) vs a bare `${VAR}` sentinel for the url (WE expand it
  # via envsubst at activation; Kiro never touches the url field).
  # `fieldName` feeds `deriveEnvVar`; `label` is only for messages.
  renderSecretValue = {
    serverName,
    fieldName,
    label,
    mkPlaceholder,
  }: value:
    if !(isCredential value)
    then {
      rendered = value;
      env = {};
    }
    else let
      hasFile = (value.file or null) != null;
      hasHelper = (value.helper or null) != null;
      var =
        if (value.var or null) != null
        then value.var
        else deriveEnvVar serverName fieldName;
      prefix = value.prefix or "";
      suffix = value.suffix or "";
      cred =
        if hasFile
        then {inherit (value) file;}
        else {inherit (value) helper;};
    in
      assert lib.assertMsg (hasFile || hasHelper) "kiro mcp secrets: ${label} on server '${serverName}' sets neither `file` nor `helper` — a credential needs exactly one.";
      assert lib.assertMsg (!(hasFile && hasHelper)) "kiro mcp secrets: ${label} on server '${serverName}' sets both `file` and `helper` — set exactly one.";
      assert lib.assertMsg (isShellName var) "kiro mcp secrets: ${label} on server '${serverName}' sets `var = \"${var}\"`, which is not a legal shell variable name (letters, digits and underscore only, not starting with a digit). It is written verbatim into the generated activation script, so an illegal name would break it at activation instead of here."; {
        rendered = "${prefix}${mkPlaceholder var}${suffix}";
        env = {${var} = cred;};
      };

  # Process one server → { server; secretEnv; urlSecretEnv; }. Non-http
  # servers (no `headers`/`url`) pass through untouched.
  processServer = serverName: server: let
    headers = server.headers or {};
    url = server.url or null;

    headerResults = mapAttrs (headerName:
      renderSecretValue {
        inherit serverName;
        fieldName = headerName;
        label = "header '${headerName}'";
        mkPlaceholder = var: "\${env:${var}}";
      })
    headers;

    urlResult =
      if url == null
      then null
      else
        renderSecretValue {
          inherit serverName;
          fieldName = "url";
          label = "url";
          mkPlaceholder = var: "\${${var}}";
        }
        url;

    serverWithHeaders =
      if headers == {}
      then server
      else server // {headers = mapAttrs (_: r: r.rendered) headerResults;};
    serverRendered =
      if urlResult == null
      then serverWithHeaders
      else serverWithHeaders // {url = urlResult.rendered;};
  in {
    server = serverRendered;
    secretEnv =
      foldl' (acc: r: acc // r.env) {} (builtins.attrValues headerResults);
    urlSecretEnv =
      if urlResult == null
      then {}
      else urlResult.env;
  };

  renderKiroSecrets = servers: let
    processed = mapAttrs processServer servers;
    # Merge one selected per-server var map across all servers. A VAR
    # bound to two DIFFERENT sources is a collision (silent last-wins
    # would export the wrong secret).
    mergeMap = sel:
      foldl' (acc: p:
        foldl' (a: name:
          if (a ? ${name}) && (a.${name} != (sel p).${name})
          then throw "kiro mcp secrets: env var '${name}' is bound to two different secret sources — give one an explicit distinct `var`."
          else a // {${name} = (sel p).${name};})
        acc (builtins.attrNames (sel p)))
      {} (builtins.attrValues processed);
    secretEnv = mergeMap (p: p.secretEnv);
    urlSecretEnv = mergeMap (p: p.urlSecretEnv);
    # Header vars (exported into the launcher env, expanded by Kiro at
    # launch) and url vars (exported at activation, expanded by our
    # envsubst) are delivered by different mechanisms at different times,
    # so a name shared between them would be ambiguous — require disjoint.
    overlap = builtins.filter (n: urlSecretEnv ? ${n}) (builtins.attrNames secretEnv);
  in
    assert lib.assertMsg (overlap == []) "kiro mcp secrets: env var(s) ${builtins.concatStringsSep ", " overlap} are bound to BOTH a header and a url — these are injected by different mechanisms (launcher env vs activation envsubst); give one an explicit distinct `var`."; {
      servers = mapAttrs (_: p: p.server) processed;
      inherit secretEnv urlSecretEnv;
    };
in {
  inherit deriveEnvVar renderKiroSecrets;
}

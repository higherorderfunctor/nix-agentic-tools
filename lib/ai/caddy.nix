# Caddyfile pieces shared by every Caddy daemon this repo renders.
#
# Each piece answers a measured hazard, not a preference; the measurements
# are recorded in dev/fragments/mcp-secrets/mcp-secrets.md. A Caddyfile
# built from them holds `{$VAR}` tokens only, so it is safe in the
# world-readable store. `lib/ai/mcpProxy.nix` is the first caller, and
# `checks/mcp-proxy/example.Caddyfile` pins its rendering byte for byte.
{
  lib,
  pkgs,
}: {
  # Caddyfile env-substitution token: `{$VAR}`, resolved by Caddy while
  # PARSING the config. This keeps the value out of the Caddyfile, but the
  # adapted JSON holds the literal value; `persist_config off` in
  # `globalBlock` keeps that JSON out of autosave.json.
  #
  # Built by explicit concatenation rather than string interpolation, and
  # that is not stylistic: in Nix `$${` is an ESCAPE for a literal `${`
  # in both quoted and indented strings, so the natural-looking
  # `"{$${var}}"` emits `{${var}}` with no substitution at all. It looks
  # right, evaluates without error, and silently produces a Caddyfile
  # that forwards to a literal unexpanded token.
  envRef = var: "{" + "$" + var + "}";

  # The global options block. `admin off` closes the admin endpoint;
  # `admin off` does NOT stop autosave, `persist_config off` does.
  #
  # Caddy's `reverse_proxy` ERROR logs embed the WHOLE request header map,
  # and its built-in redaction covers only `Authorization`, `Cookie`,
  # `Set-Cookie` and `Proxy-Authorization`. `logDeletes` names the log
  # fields to drop. Name whole maps (`request>headers`), never single
  # fields: a per-field list is a denylist that fails OPEN on any header
  # nobody enumerated. An empty list would render an unfiltered log, so it
  # throws rather than letting the safe posture depend on the caller.
  globalBlock = {logDeletes}:
    if logDeletes == []
    then throw "lib/ai/caddy.nix globalBlock: `logDeletes` is empty, which would log every request header in clear. Name at least `request>headers`."
    else
      lib.concatStringsSep "\n" (
        [
          "{"
          "\tadmin off"
          "\tauto_https off"
          "\tpersist_config off"
          "\tlog {"
          "\t\toutput stderr"
          "\t\tformat filter {"
          "\t\t\twrap console"
          "\t\t\tfields {"
        ]
        ++ map (field: "\t\t\t\t${field} delete") logDeletes
        ++ [
          "\t\t\t}"
          "\t\t}"
          "\t}"
          "}"
        ]
      );

  # Headers Caddy's `reverse_proxy` ADDS on its own; a caller deletes each
  # with `header_up -<name>` so the upstream sees the request the client
  # sent. `header_up -<name>` deletes rather than overwrites.
  #
  # Note the scope: this list hides the PROXY, not the client. Deleting
  # what the CLIENT sends is a different question with a different answer
  # — it was tried on 2026-08-12 and removed, because stripping client
  # defaults produced a header set no ordinary client sends, which is more
  # distinctive, not less. Do not add client headers to this list.
  #
  # Not cosmetic. These announce a proxy hop to the far end: they can
  # trip WAF rules, change how an upstream derives a client identity, and
  # they leak the loopback address and port the client actually used.
  #
  # `Via` belongs here for the same reason as the X-Forwarded-* trio and
  # is the one people forget: Caddy sends `Via: 1.1 Caddy`, which both
  # announces the hop and names the proxy. Measured — dropping the
  # X-Forwarded-* headers does NOT cover it.
  #
  # This list is not derived from anything, so a Caddy release adding a
  # FIFTH header would go unnoticed here. The diff-the-two-requests probe
  # recorded in dev/fragments/mcp-secrets/mcp-secrets.md is what actually
  # catches a new one — re-run it on a Caddy bump.
  strippedHopHeaders = [
    "Via"
    "X-Forwarded-For"
    "X-Forwarded-Host"
    "X-Forwarded-Proto"
  ];

  # `reverse_proxy` body lines, unindented; the caller indents them.
  # `flush_interval -1` disables response buffering, which is what keeps
  # streamed (SSE) responses incremental rather than arriving in one lump
  # at the end. `compression off` covers what `strippedHopHeaders` cannot:
  # Go's HTTP transport adds `Accept-Encoding: gzip` below the header
  # layer, so no `header_up -` reaches it.
  proxyTuning = [
    "flush_interval -1"
    "transport http {"
    "\tcompression off"
    "}"
  ];

  # Shell lines that end a run script: point Caddy's config and data
  # directories at a 0700 per-daemon runtime directory, so instance state
  # never lands in the user's persistent XDG directories and two daemons
  # never share a Caddy state path, then exec `caddy` on the Caddyfile
  # `config`. `name` must be unique per daemon; `caddy` is the build to
  # run.
  runCaddy = {
    name,
    caddy,
    config,
  }: ''
    _state="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/${name}"
    ${pkgs.coreutils}/bin/mkdir -p "$_state"
    ${pkgs.coreutils}/bin/chmod 0700 "$_state"
    export XDG_CONFIG_HOME="$_state/config" XDG_DATA_HOME="$_state/data"

    exec ${lib.getExe caddy} run --config ${config} --adapter caddyfile
  '';
}

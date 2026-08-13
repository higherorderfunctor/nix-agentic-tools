# Local credential-injecting reverse proxy for REMOTE http MCP servers.
#
# ── Why this exists ───────────────────────────────────────────────────
# A remote `type = "http"` MCP server needs credentials, and the only
# other delivery path in this repo puts them on the CLIENT: a
# `${env:VAR}` header placeholder in mcp.json, with the value exported by
# the kiro launcher. That couples the credential to WHICH BINARY runs,
# while mcp.json is user-global — so any other kiro on PATH reads the
# same server list and connects with NO credentials, silently, because
# only the remote end can tell. See the KNOWN LIMITATION section of
# dev/fragments/mcp-secrets/mcp-secrets.md.
#
# This moves the credential to a DAEMON instead. A systemd user service
# runs Caddy, reads each secret from its file at START, and exposes an
# UNAUTHENTICATED loopback endpoint. The client entry becomes a plain
# `{ type = "http"; url = "http://127.0.0.1:<port>/"; }` carrying no
# credential at all, so it is harness-agnostic: kiro, Claude Code,
# Copilot, wrapped or not, it makes no difference.
#
# ── Where the secret is, and is NOT ───────────────────────────────────
#   * in the daemon's environment  — /proc/<pid>/environ is 0400
#   * NOT in argv                  — /proc/<pid>/cmdline is 0444, i.e.
#                                    world-readable. Command substitution
#                                    does NOT help: the shell expands it
#                                    before execve(), so the kernel stores
#                                    the literal value. Measured. (Spelled
#                                    without the two-word form on purpose —
#                                    checks/bare-commands.nix scans comments
#                                    too and would read it as a bare call.)
#   * NOT in the Caddyfile         — it holds `{$VAR}` placeholders only
#   * NOT in mcp.json              — no header reaches any client
#   * NOT in the Nix store
#
# Caddy substitutes `{$VAR}` while PARSING the config, so a decrypted
# value exists only in the daemon's memory and environment.
#
# The upstream request is BYTE-IDENTICAL to the un-proxied one plus the
# injected `proxy.headers` — see `strippedHopHeaders` for what that costs
# and for the one header a header rule cannot reach.
#
# The proxy adds no identity of its own and erases none of the client's.
# A 2026-08-12 experiment did the latter — normalizing `User-Agent` and
# deleting two undici artifacts — and was REMOVED the next day after
# measurement killed the rationale. Do not reintroduce it without new
# evidence; the reasoning is recorded in
# dev/fragments/mcp-secrets/mcp-secrets.md so it does not get re-derived
# from the same wrong intuition.
#
# Verified end-to-end against a local fake upstream: an upstream URL
# carrying a path is rewritten correctly, responses stream incrementally
# (`flush_interval -1`), argv is clean, both failure modes are loud.
#
# ── The journal is a secret sink, and Caddy will not save you ──────────
# Caddy's `reverse_proxy` ERROR logs embed the WHOLE request header map,
# so every credential injected below lands in the systemd journal in
# cleartext unless the log is filtered. Caddy's built-in `log_credentials`
# (default false) redacts ONLY `Authorization`, `Cookie`, `Set-Cookie`
# and `Proxy-Authorization` — this proxy injects none of those, it
# injects CUSTOM auth headers, which are logged verbatim. Measured
# 2026-08-12 on a live pair of units: 35 journal lines carrying a gateway
# API key, on a persistent journal, dating to the day they first started.
#
# The fix DROPS THE WHOLE HEADER MAP (`request>headers delete`) rather
# than naming the secret fields, and that distinction is the point. A
# per-field list is a denylist: correct only for the credentials someone
# remembered to enumerate, and it fails OPEN on anything new — a header
# added later, one whose name is computed, or one a future Caddy starts
# emitting. Dropping the map fails CLOSED. Measured: a credential header
# that no rule mentioned did not appear in the log.
#
# Per-server attribution therefore does NOT come from a logged header. It
# comes from the unit — one `mcp-proxy-<name>.service` per server, with an
# explicit `SyslogIdentifier` so an unfiltered `journalctl` shows a stable
# name rather than the ExecStart store hash. Use
# `journalctl --user -u mcp-proxy-<name>` to tell two proxies apart.
#
# ── Scope ─────────────────────────────────────────────────────────────
# Home Manager on Linux only. devenv parity (process-compose) and Darwin
# (launchd) are deliberately OUT OF SCOPE and explicitly NOT decided
# against — a deferral, not a WONTFIX. `devenvTransform` throws rather
# than silently ignoring `proxy.enable`.
{
  lib,
  pkgs,
}: let
  inherit (lib) concatStringsSep filterAttrs foldl' mapAttrs mapAttrsToList;

  credentialsLib = import ../credentials.nix {inherit lib;};

  # Upper-case; every non-alphanumeric becomes '_'. Same shape as the
  # Kiro preprocessor's `deriveEnvVar`, deliberately NOT shared with it:
  # this is ~10 similar LINES, and the repo's DRY rule prefers that to
  # prying a working secret path apart to serve a second caller.
  sanitize = s:
    lib.concatStrings (map
      (c:
        if lib.match "[A-Z0-9]" c != null
        then c
        else "_")
      (lib.stringToCharacters (lib.toUpper s)));

  envVarFor = serverName: field: "MCP_PROXY_${sanitize serverName}_${sanitize field}";

  # Caddyfile env-substitution token: `{$VAR}`, resolved by Caddy while
  # PARSING the config, which is what keeps the value out of the file.
  #
  # Built by explicit concatenation rather than string interpolation, and
  # that is not stylistic: in Nix `$${` is an ESCAPE for a literal `${`
  # in both quoted and indented strings, so the natural-looking
  # `"{$${var}}"` emits `{${var}}` with no substitution at all. It looks
  # right, evaluates without error, and silently produces a Caddyfile
  # that forwards to a literal unexpanded token.
  envRef = var: "{" + "$" + var + "}";

  # Headers Caddy's `reverse_proxy` ADDS on its own, deleted so the
  # upstream sees byte-identical requests to what the client sent direct
  # (plus the injected credentials, which is the whole point).
  #
  # Note the scope: this list hides the PROXY, not the client. Deleting
  # what the CLIENT sends is a different question with a different answer
  # — it was tried on 2026-08-12 and removed, because the headers in
  # question (`User-Agent: node`, `Accept-Language: *`,
  # `Sec-Fetch-Mode: cors`) are undici defaults identifying Node rather
  # than any harness, while `Mcp-Protocol-Version` gives the traffic away
  # regardless and cannot be removed. Stripping them produced a header
  # set no ordinary Node client sends, which is more distinctive, not
  # less. Do not add client headers to this list.
  #
  # Not cosmetic. These announce a proxy hop to the far end: they can
  # trip WAF rules, change how an upstream derives a client identity, and
  # they leak the loopback address and port the client actually used.
  # A request shape that differs from the pre-proxy one is also a
  # difference you would have to rule out first when debugging a remote
  # 4xx, which is exactly the wrong time to discover it.
  #
  # `Via` belongs here for the same reason as the X-Forwarded-* trio and
  # is the one people forget: Caddy sends `Via: 1.1 Caddy`, which both
  # announces the hop and names the proxy. Measured — dropping the
  # X-Forwarded-* headers does NOT cover it.
  #
  # `header_up -<name>` deletes rather than overwrites. This list is not
  # derived from anything, so a Caddy release adding a FIFTH header would
  # go unnoticed here; the `module-mcp-proxy-*` checks only pin the
  # directives we emit. The diff-the-two-requests probe recorded in
  # dev/fragments/mcp-secrets/mcp-secrets.md is what actually catches a
  # new one — re-run it on a Caddy bump.
  #
  # Note what this list CANNOT fix: `Accept-Encoding: gzip` is added by
  # Go's HTTP transport, below the header layer, so no `header_up -`
  # reaches it. That one needs `transport http { compression off }` in
  # the Caddyfile below.
  strippedHopHeaders = [
    "Via"
    "X-Forwarded-For"
    "X-Forwarded-Host"
    "X-Forwarded-Proto"
  ];

  isCredential = v: builtins.isAttrs v && (v ? file || v ? helper);

  isProxied = srv: let
    p = srv.proxy or null;
  in
    p != null && (p.enable or false);

  proxiedServers = servers: filterAttrs (_: isProxied) servers;

  # ── Client-facing entry ─────────────────────────────────────────────
  # The real `url` is replaced by the loopback one, so no credential url
  # reaches the client. `timeout` survives: it is client behavior, not a
  # credential, and some upstreams are slow on large result sets.
  #
  # Server-level `headers` DO reach the client, and that is the point of
  # the split: since 2026-08-13 they mean exactly one thing — what the
  # CLIENT sends — while everything the proxy injects lives under
  # `proxy.headers`. Passing them through is what makes the two
  # non-overlapping instead of one key with two meanings.
  #
  # They cannot carry a secret: `mkBackendTransform` asserts that a
  # proxied server's top-level `headers` are all plain strings, precisely
  # so this line is safe. If that assertion is ever relaxed, this becomes
  # a credential leak to the client and the whole proxy is pointless.
  clientEntry = _name: srv:
    {
      type = "http";
      url = "http://${srv.proxy.host}:${toString srv.proxy.port}/";
    }
    // lib.optionalAttrs ((srv.headers or {}) != {}) {
      inherit (srv) headers;
    }
    // lib.optionalAttrs ((srv.timeout or null) != null) {
      inherit (srv) timeout;
    };

  # ── One secretValue → { rendered; secrets; } ────────────────────────
  # A plain string is literal config. A credential becomes
  # `<prefix>{$VAR}<suffix>` plus the VAR→credential binding the wrapper
  # exports. prefix/suffix stay in the CONFIG rather than in the exported
  # value, so the env var holds the raw secret and nothing else — which
  # also means rotating the file needs no change here.
  #
  # The token itself comes from `envRef` — see the escaping trap noted
  # there before rewriting this as an interpolated string.
  renderValue = serverName: field: value:
    if !(isCredential value)
    then {
      rendered = value;
      secrets = {};
    }
    else let
      var =
        if (value.var or null) != null
        then value.var
        else envVarFor serverName field;
      prefix = value.prefix or "";
      suffix = value.suffix or "";
      cred =
        if (value.file or null) != null
        then {inherit (value) file;}
        else {inherit (value) helper;};
    in {
      rendered = prefix + envRef var + suffix;
      secrets = {${var} = cred;};
    };

  # ── Per-server proxy spec ───────────────────────────────────────────
  # The upstream url is split into ORIGIN and PATH at RUNTIME by the
  # wrapper rather than here, because it may itself be a credential and
  # so is unknown at eval time. Caddy's `reverse_proxy` accepts a scheme
  # and host in its upstream but NOT a path, which is why the split plus
  # a `rewrite` is needed at all.
  #
  # Headers come from `srv.proxy.headers` — what the DAEMON injects —
  # never from `srv.headers`, which is the client's own config. Before
  # 2026-08-13 the top-level `headers` were absorbed here when
  # `proxy.enable` was set, so one key meant "the client sends this"
  # normally and "the proxy injects this" when a sibling flag was on.
  # That is reversed; do not reinstate the absorption.
  #
  # A null VALUE is a deletion rather than an injection, so it is filtered
  # out here and emitted as `header_up -<name>` instead.
  specFor = serverName: srv: let
    url = srv.url or null;
    urlCred = isCredential url;
    declared = srv.proxy.headers or {};
    headerResults =
      mapAttrs (h: renderValue serverName h)
      (filterAttrs (_: v: v != null) declared);
  in {
    name = serverName;
    inherit (srv.proxy) host port;

    originVar = envVarFor serverName "origin";
    pathVar = envVarFor serverName "path";
    urlVar = envVarFor serverName "url";

    # Exactly one of these is set. A literal url is exported by the
    # wrapper the same way a secret one is, so the runtime split has a
    # single shape instead of an eval-time and a runtime variant.
    urlSecret =
      if urlCred
      then
        (
          if (url.file or null) != null
          then {inherit (url) file;}
          else {inherit (url) helper;}
        )
      else null;
    urlLiteral =
      if urlCred
      then null
      else url;

    headers = mapAttrs (_: r: r.rendered) headerResults;
    headerSecrets =
      foldl' (acc: r: acc // r.secrets) {}
      (builtins.attrValues headerResults);

    # Headers the operator set to null: forwarded as deletions so a client
    # header can be dropped before it reaches the upstream.
    deletedHeaders = builtins.attrNames (filterAttrs (_: v: v == null) declared);
  };

  # ── Caddyfile ───────────────────────────────────────────────────────
  # `bind <host>` is what restricts the listener to an interface. This is
  # the part that is easy to get wrong, and getting it wrong is a
  # security bug: a bare `:<port>` site address listens on EVERY
  # interface, publishing this UNAUTHENTICATED endpoint to the network
  # while `proxy.host` sits unused and the client entry still claims
  # loopback. This repo has shipped that same defect before in
  # `service.host`.
  #
  # Writing the host into the SITE ADDRESS (`127.0.0.1:9501 { … }`) does
  # NOT fix it and quietly breaks the proxy instead — measured. In Caddy
  # a site address host is a Host-HEADER MATCHER, not a bind: the
  # listener still covers every interface, and every request whose Host
  # header is not exactly `127.0.0.1:9501` now 400s, loopback included
  # once a client addresses it any other way. Use `bind`.
  #
  # Holds `{$VAR}` placeholders only, so it is safe in the
  # world-readable store. `flush_interval -1` disables response
  # buffering, which is what keeps MCP streamable-HTTP / SSE responses
  # incremental rather than arriving in one lump at the end.
  #
  # `rewrite *` sends EVERY client path to the upstream's path. That is
  # correct for MCP streamable HTTP, which is a single endpoint, and it
  # is why the loopback url handed to clients is a bare `/`.
  # The global log block. `request>headers delete` removes the ENTIRE
  # header map from every log entry — see the header comment for why this
  # is a whole-map drop rather than a list of secret field names.
  #
  # It is unconditional even for a proxy that injects no credential. A
  # conditional here would mean the safe posture depended on the server's
  # shape, so adding a credential to an existing server would silently
  # switch logging from safe to leaky. Constant beats clever.
  #
  # Everything actually used for debugging survives: upstream, duration,
  # remote_ip, proto, method, host, uri, and the error itself. Only the
  # headers go. Measured against the abort path that produced the leak.
  logBlock = concatStringsSep "\n" [
    "\tlog {"
    "\t\toutput stderr"
    "\t\tformat filter {"
    "\t\t\twrap console"
    "\t\t\tfields {"
    "\t\t\t\trequest>headers delete"
    "\t\t\t}"
    "\t\t}"
    "\t}"
  ];

  # Assembled as a line LIST rather than interpolated into the indented
  # string, so an empty header set cannot leave a stray blank line in the
  # emitted config.
  reverseProxyBody = spec:
    concatStringsSep "\n" (
      (mapAttrsToList (h: v: "\t\theader_up ${h} \"${v}\"") spec.headers)
      ++ (map (h: "\t\theader_up -${h}") spec.deletedHeaders)
      ++ (map (h: "\t\theader_up -${h}") strippedHopHeaders)
      ++ [
        "\t\tflush_interval -1"
        "\t\ttransport http {"
        "\t\t\tcompression off"
        "\t\t}"
      ]
    );

  caddyfileFor = spec:
    pkgs.writeText "mcp-proxy-${spec.name}-Caddyfile" ''
      {
      	admin off
      	auto_https off
      ${logBlock}
      }

      :${toString spec.port} {
      	bind ${spec.host}
      	rewrite * ${envRef spec.pathVar}
      	reverse_proxy ${envRef spec.originVar} {
      ${reverseProxyBody spec}
      	}
      }
    '';

  # ── ExecStart wrapper ───────────────────────────────────────────────
  # Reads every secret from its file (absolute coreutils paths, empty and
  # missing-file guards — see lib/credentials.nix), splits the upstream
  # url into origin and path, then execs Caddy. Nothing lands in argv.
  #
  # Failing CLOSED here is deliberate and differs from the kiro launcher,
  # which cannot refuse to start the user's editor. A proxy that starts
  # without its credential would answer every client with a 401 from the
  # upstream and look like a broken remote, so it exits instead.
  startScriptFor = spec: let
    secretExports =
      concatStringsSep "\n"
      (mapAttrsToList
        (var: cred: credentialsLib.mkSecretExport pkgs var cred)
        (spec.headerSecrets
          // lib.optionalAttrs (spec.urlSecret != null) {
            ${spec.urlVar} = spec.urlSecret;
          }));

    literalUrlAssignment = lib.optionalString (spec.urlLiteral != null) ''
      ${spec.urlVar}=${lib.escapeShellArg spec.urlLiteral}
      export ${spec.urlVar}
    '';
  in
    pkgs.writeShellScript "mcp-proxy-${spec.name}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${secretExports}
      ${literalUrlAssignment}

      # Split "<scheme>://<host>[/<path>]" into the two pieces Caddy
      # needs. `reverse_proxy` rejects a path in its upstream, so the
      # path is applied with `rewrite` instead. The `case` is load
      # bearing: with no '/' after the host, "''${_rest#*/}" returns
      # _rest unchanged and the path would silently become the hostname.
      _url="''${${spec.urlVar}}"
      _scheme="''${_url%%://*}"
      _rest="''${_url#*://}"
      case "$_rest" in
        */*)
          _host="''${_rest%%/*}"
          _path="/''${_rest#*/}"
          ;;
        *)
          _host="$_rest"
          _path="/"
          ;;
      esac

      ${spec.originVar}="$_scheme://$_host"
      ${spec.pathVar}="$_path"
      export ${spec.originVar} ${spec.pathVar}

      exec ${lib.getExe pkgs.caddy} run \
        --config ${caddyfileFor spec} \
        --adapter caddyfile
    '';
in {
  inherit
    caddyfileFor
    clientEntry
    envVarFor
    isProxied
    proxiedServers
    specFor
    startScriptFor
    ;
}

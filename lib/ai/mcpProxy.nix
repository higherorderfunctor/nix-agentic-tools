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
# UNAUTHENTICATED loopback endpoint. Proxy ownership is keyed by the MCP
# server attribute name: a used top-level declaration owns one shared unit,
# while a runtime-scoped declaration owns its unit directly. Reusing a key
# across proxy declarations is rejected by ai.claims.service. The client entry becomes a plain
# `{ type = "http"; url = "http://127.0.0.1:<port>/"; }` carrying no
# credential at all, so it is harness-agnostic: kiro, Claude Code,
# Copilot, wrapped or not, it makes no difference.
#
# ── Where the secret is, and is NOT ───────────────────────────────────
#   * in the daemon's environment  — a same-uid process can read
#                                    /proc/<pid>/environ; Yama
#                                    ptrace_scope=1 does not block it
#   * NOT in argv                  — /proc/<pid>/cmdline is 0444, i.e.
#                                    world-readable. Command substitution
#                                    does NOT help: the shell expands it
#                                    before execve(), so the kernel stores
#                                    the literal value. Measured. (Spelled
#                                    without the two-word form on purpose —
#                                    checks/shell/bare-commands.nix scans comments
#                                    too and would read it as a bare call.)
#   * NOT in the Caddyfile         — it holds `{$VAR}` placeholders only
#   * NOT in Caddy autosave        — `persist_config off` prevents it;
#                                    older generations may have left
#                                    autosave.json behind
#   * NOT in mcp.json              — no header reaches any client
#   * NOT in the Nix store
#
# Caddy substitutes `{$VAR}` while PARSING the config, so the adapted JSON
# holds literal values. `persist_config off` prevents Caddy from writing that
# active config to autosave.json. The run script below points Caddy's
# config and data directories at a per-proxy runtime directory, so instance
# state never lands in the user's persistent XDG directories and two proxies
# never share a Caddy state path. The process itself is an ordinary
# `ai.services` entry; no proxy-specific service writer exists.
#
# The upstream request is BYTE-IDENTICAL to the un-proxied one plus the
# injected `proxy.headers` — see `strippedHopHeaders` and `proxyTuning` in
# lib/ai/caddy.nix for what that costs and for the one header a header
# rule cannot reach.
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
# The fix DROPS THE WHOLE HEADER MAP (`request>headers delete`, through
# `globalBlock` in lib/ai/caddy.nix) rather
# than naming the secret fields, and that distinction is the point. A
# per-field list is a denylist: correct only for the credentials someone
# remembered to enumerate, and it fails OPEN on anything new — a header
# added later, one whose name is computed, or one a future Caddy starts
# emitting. Dropping the map fails CLOSED. Measured: a credential header
# that no rule mentioned did not appear in the log.
#
# Per-server attribution therefore does NOT come from a logged header. It
# comes from the unit — one `mcp-proxy-<name>.service` per server. Use
# `journalctl --user -u mcp-proxy-<name>` to tell two proxies apart.
#
# ── Scope ─────────────────────────────────────────────────────────────
# Home Manager runs the proxy through `ai.services` on Linux and warns on
# Darwin, where launchd is unsupported. Devenv emits a process through
# `ai.services`, started with `devenv up`.
{
  lib,
  pkgs,
}: let
  inherit (lib) concatStringsSep filterAttrs foldl' mapAttrs mapAttrsToList;

  strictShellApplication = import ../strict-shell-application.nix;
  mcp = import ../mcp.nix {inherit lib;};
  caddy = import ./caddy.nix {inherit lib pkgs;};
  inherit (caddy) envRef;
  redact = import ../redact {inherit lib;};

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

  inherit (redact) isReserved;

  isProxied = srv:
    builtins.isAttrs srv
    && (let
      p = srv.proxy or null;
    in
      p != null && (p.enable or false));

  # Typed remote entries (`mcp.resolveRemote`) are resolved first, so a
  # reserved-`settings` declaration is proxied exactly like a hand-written one.
  proxiedServers = servers: filterAttrs (_: isProxied) (mapAttrs mcp.resolveRemote servers);

  # ── Client-facing entry ─────────────────────────────────────────────
  # The real `url` is replaced by the loopback one, so no credential url
  # reaches the client. `timeout` and `toolPolicy` survive: they are client
  # behavior, not credentials, and some upstreams are slow on large result
  # sets.
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
    }
    // lib.optionalAttrs ((srv.toolPolicy or {}) != {}) {
      inherit (srv) toolPolicy;
    };

  # Lower proxy declarations at EACH ownership scope before root/runtime
  # composition. A top-level proxy therefore fans out only this credential-free
  # client record; its managed unit stays owned by the top-level declaration.
  # Runtime-scoped proxies lower independently and own their units directly.
  # Null tombstones must survive this pass so mergePool can apply them after
  # precedence.
  lowerClientEntries = servers:
    mapAttrs
    (name: declared: let
      srv = mcp.resolveRemote name declared;
    in
      if isProxied srv
      then clientEntry name srv
      else srv)
    servers;

  # Validation belongs to the declaration that owns the managed proxy, not to
  # every runtime view that happens to inherit its lowered client entry.
  assertionsFor = {
    key,
    optionPath,
    server,
  }: [
    {
      assertion = (server.url or null) != null;
      message = "${optionPath}: ${key} set `proxy.enable` but no `url`. The proxy forwards to that url, so there is nothing to proxy to — set `url` (a plain string or a credential), or drop `proxy.enable`.";
    }
    {
      assertion = !(builtins.any isReserved (builtins.attrValues (server.headers or {})));
      message = "${optionPath}: ${key} set `proxy.enable` and put a CREDENTIAL in the server's top-level `headers`. On a proxied server those are the CLIENT's headers and are written into its config, which would hand it the credential the proxy exists to withhold. Move them to `proxy.headers`, where the daemon injects them and no client ever sees the value. (Top-level `headers` used to be absorbed into the daemon automatically; that behavior was removed so the key means one thing.)";
    }
  ];

  # The whole composed value is read once into a consumer-owned variable.
  renderValue = serverName: field: value:
    if builtins.isString value
    then {
      rendered = value;
      secrets = {};
    }
    else let
      var = envVarFor serverName "header_${field}";
    in {
      rendered = envRef var;
      secrets = {${var} = value;};
    };

  # ── Per-server proxy spec ───────────────────────────────────────────
  # The upstream url is split into ORIGIN and PATH at RUNTIME by the
  # redact reader rather than here, because it may itself be a credential and
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
    urlCred = isReserved url;
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
    # service launcher the same way a secret one is, so the split has a
    # single shape instead of an eval-time and a runtime variant.
    urlSecret =
      if urlCred
      then url
      else null;
    urlLiteral =
      if urlCred
      then null
      else url;

    headers = mapAttrs (_: r: r.rendered) headerResults;
    headerSecrets = foldl' (acc: r:
      if lib.any (var: acc ? ${var} && acc.${var} != r.secrets.${var}) (builtins.attrNames r.secrets)
      then throw "MCP proxy ${serverName}: headers derive the same variable; rename one header."
      else acc // r.secrets) {}
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
  # The global log drops the WHOLE header map — see the header comment. It
  # is unconditional even for a proxy that injects no credential. A
  # conditional here would mean the safe posture depended on the server's
  # shape, so adding a credential to an existing server would silently
  # switch logging from safe to leaky. Constant beats clever.
  #
  # Everything actually used for debugging survives: upstream, duration,
  # remote_ip, proto, method, host, uri, and the error itself. Only the
  # headers go. Measured against the abort path that produced the leak.
  globalBlock = caddy.globalBlock {logDeletes = ["request>headers"];};

  # Assembled as a line LIST rather than interpolated into the indented
  # string, so an empty header set cannot leave a stray blank line in the
  # emitted config.
  reverseProxyBody = spec:
    concatStringsSep "\n" (
      (mapAttrsToList (h: v: "\t\theader_up ${h} \"${v}\"") spec.headers)
      ++ (map (h: "\t\theader_up -${h}") spec.deletedHeaders)
      ++ (map (h: "\t\theader_up -${h}") caddy.strippedHopHeaders)
      ++ (map (line: "\t\t${line}") caddy.proxyTuning)
    );

  caddyfileFor = spec:
    pkgs.writeText "mcp-proxy-${spec.name}-Caddyfile" ''
      ${globalBlock}

      :${toString spec.port} {
      	bind ${spec.host}
      	rewrite * ${envRef spec.pathVar}
      	reverse_proxy ${envRef spec.originVar} {
      ${reverseProxyBody spec}
      	}
      }
    '';

  # ── Run script ──────────────────────────────────────────────────────
  # The launcher exports the resolved url and header secrets; this script
  # splits "<scheme>://<host>[/<path>]" into the two pieces Caddy needs
  # (`reverse_proxy` rejects a path in its upstream, so the path is applied
  # with `rewrite`), then `runCaddy` isolates Caddy's state and execs it.
  # The `case` is load bearing: with no '/' after the host,
  # "''${_rest#*/}" returns _rest unchanged and the path would silently
  # become the hostname.
  runScriptFor = spec:
    strictShellApplication pkgs {
      name = "mcp-proxy-${spec.name}";
      text = ''
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
        export ${spec.originVar}="$_scheme://$_host" ${spec.pathVar}="$_path"

        ${caddy.runCaddy {
          name = "mcp-proxy-${spec.name}";
          inherit (pkgs) caddy;
          config = caddyfileFor spec;
        }}'';
    };

  # The `ai.services` entry for one proxy declaration. Secrets stay
  # references: the generic launcher resolves them at start.
  serviceFor = name: server: let
    spec = specFor name server;
  in {
    command = [(lib.getExe (runScriptFor spec))];
    environment =
      spec.headerSecrets
      // {
        ${spec.urlVar} =
          if spec.urlSecret != null
          then spec.urlSecret
          else spec.urlLiteral;
      };
    ports.main = spec.port;
  };
in {
  inherit
    assertionsFor
    caddyfileFor
    clientEntry
    envVarFor
    isProxied
    lowerClientEntries
    proxiedServers
    runScriptFor
    serviceFor
    specFor
    ;
}

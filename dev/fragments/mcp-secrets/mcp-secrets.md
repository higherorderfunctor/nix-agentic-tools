## SOPS-Injectable Remote HTTP MCP Servers

> **Last verified:** 2026-08-15 (commit pending — replaces accidental
> cross-runtime systemd-definition deduplication with explicit proxy ownership:
> a used top-level declaration owns one shared managed proxy and fans out only
> its lowered client entry; runtime-scoped declarations own proxies directly;
> reused server/ownership keys fail with an actionable diagnostic; and an unused
> top-level proxy is not materialized. The ownership scan dynamically discovers
> every MCP-capable `mkAiApp` runtime from the option tree, so public/custom
> runtimes cannot receive a dead loopback entry or evade the reused-key guard).
> Prior: 2026-08-13 (commit pending — the proxy was writing every injected
> credential to the systemd journal in CLEARTEXT, because Caddy's reverse_proxy
> error logs embed the whole request header map and its built-in
> `log_credentials` covers only Authorization/Cookie, never the custom auth
> headers this proxy exists to inject. Measured on live units: 35 journal lines
> carrying a gateway API key. Fixed by dropping the WHOLE header map rather than
> naming secret fields — a per-field list is a denylist that fails open, and
> abandoning it also deleted the canonical-casing trap it required. Attribution
> moves to an explicit per-unit `SyslogIdentifier`. SPLITS the header surface:
> `<server>.headers` are the CLIENT's and asserted credential-free,
> `proxy.headers` are what the daemon injects, with `null` meaning delete;
> absorption is gone. Records that client-identity masking was tried on
> 2026-08-12 and REMOVED — the headers are undici defaults, not harness
> markers). Prior: 2026-08-06 (commit pending — adds the LOCAL
> CREDENTIAL-INJECTING PROXY (`proxy.enable`, `lib/ai/mcpProxy.nix`), which
> retires the per-binary scope mismatch below for any server that opts in: the
> credential moves into a systemd user daemon and the client gets an
> unauthenticated loopback url, so no client holds a credential to get wrong.
> Records the measured argv-vs-environ fact that decides the whole design, and
> the Nix `$${` escaping trap that silently produces an unexpanded Caddy token.
> HM + Linux only; devenv and Darwin are deferred, NOT WONTFIX). Prior:
> 2026-08-04 (commit pending — records the PER-BINARY vs USER-GLOBAL scope
> mismatch that lets a devshell kiro connect to gateway MCP servers with no
> credentials, and the `export VAR="$(cat …)"` masking that makes an unreadable
> secret silent; the url writer now fails loudly, the launcher wrapper
> deliberately does not). Prior: 2026-08-04 (commit pending — rebased onto the
> extracted launcher wrapper: `wrapKiroPackage` no longer lives in `mkKiro.nix`
> and no longer uses `makeWrapper`, so the secret export moved into
> `packages/kiro-cli/lib/wrapPackage.nix` as a shell `export` line beside
> `envExports`). Prior: 2026-07-23 (Option B: SOPS url + `mcpWriteMode`). If you
> change the `secretValue` shape, the Kiro placeholder/preprocessor, the
> `renderServer` guard, the wrapper export, the mcp.json writer, proxy lowering,
> or managed-proxy ownership/registration and this fragment isn't updated in the
> same commit, stop and fix it.

A `type = "http"` MCP server (`ai.mcpServers` / `ai.kiro.mcpServers`) can take
SOPS/agenix-injected `headers` and `url` so secrets never land in the
world-readable store or in committed config. Files:

- `lib/ai/mcpServer/commonSchema.nix` — the (C) http shape; `url` and each
  `headers.<name>` are `secretValue`.
- `lib/ai/mcpServer/secretValue.nix` — `either str credential`
  (`{ file | helper; prefix?; suffix?; var?; }`).
- `lib/ai/app/mkBackendTransform.nix` — declaration-scope client lowering; its
  internal normalized-pool marker is the dynamic discovery boundary for custom
  app records.
- `lib/ai/sharedOptions.nix` — cross-record owner aggregation, validation, and
  Home Manager unit materialization.
- `lib/mcp.nix` `renderServer` — the shared renderer + non-Kiro throw.
- `packages/kiro-cli/lib/mcpSecrets.nix` — Kiro preprocessor.
- `packages/kiro-cli/lib/mkKiro.nix` — `mkMcpJsonScript` + wiring.
- `packages/kiro-cli/lib/wrapPackage.nix` — `secretEnv` → the runtime `export`
  that puts the decrypted value in the launcher's env.

### The proxy path — `proxy.enable`, and why it is the preferred one

`proxy.enable` on a `type = "http"` server moves the credential OFF the client
entirely. `lib/ai/mcpProxy.nix` builds the Caddy daemon and its lowered client
entry; `lib/ai/sharedOptions.nix` owns declaration identity and materializes
`systemd.user.services.mcp-proxy-<name>`. The daemon reads each secret from its
file at START, injects the headers outbound, and listens UNAUTHENTICATED on
loopback. Clients get `{ type = "http"; url = "http://127.0.0.1:<port>/"; }`.

Ownership is explicit and keyed by the MCP server attribute name:

- a used top-level `ai.mcpServers.<name>` proxy owns one shared managed daemon;
  only its lowered credential-free client entry fans out to capable runtimes;
- `ai.<runtime>.mcpServers.<name>` owns its daemon directly and replaces or
  suppresses the top-level client entry through the ordinary pool contract;
- reusing `<name>` for two proxy owners fails even when their definitions are
  byte-identical, because both would name `mcp-proxy-<name>.service`; direct
  owners must use different server keys; and
- a top-level proxy inherited by no enabled capable runtime is not materialized.

The ownership guard omits every conflicted unit before module merging, so a
generic duplicate-definition failure cannot hide the actionable key/scope
diagnostic. Runtime-scoped daemon lifetime follows its declaration, while the
top-level owner is lazy because it exists solely to serve its enabled fanout
consumers. `sharedOptions.nix` discovers every runtime option subtree carrying
the internal `_normalizedPools.mcpServers` capability marker;
`mkBackendTransform.nix` declares it exactly when the app record's
`supportedPools` contains `mcpServers`. The explicit marker is load-bearing:
public records may have an unrelated same-named native `mcpServers` option when
they do not support the normalized pool. Discovery must remain dynamic because a
hard-coded first-party runtime list would let custom runtimes receive lowered
loopback entries without an owner or evade duplicate-key diagnostics.

This is not merely a nicer delivery mechanism — it dissolves the scope mismatch
documented below, because **there is no client-side credential left to get
wrong.** It also stops being Kiro-only: `renderServer` throws when a credential
reaches Claude/Copilot/the shared pool, and the proxied entry contains none, so
those ecosystems can consume it.

**Where the secret is, and is not** — the measurement that decides the design:

| Location                  | Mode   | Secret there?                     |
| ------------------------- | ------ | --------------------------------- |
| `/proc/<pid>/environ`     | `0400` | yes                               |
| `/proc/<pid>/cmdline`     | `0444` | **never**                         |
| the Caddyfile (Nix store) | `0444` | never — `{$VAR}` tokens only      |
| `mcp.json`                | varies | never                             |
| the systemd journal       | varies | never — but only since 2026-08-13 |

That last row is the one this table originally missed, and it was wrong for the
whole life of the feature — see the journal section below. Treat any NEW sink (a
log, a metric label, an error message) as guilty until measured; the four rows
above were each reasoned about deliberately, and the journal still got through
because nothing in the design put a credential there on purpose.

**`$(cat …)` does NOT keep a secret out of argv.** The shell expands command
substitution BEFORE `execve()`, so the kernel stores the literal value and any
local user can read it. Measured 2026-08-06: a process spawned as
`… -H X-Token "$(cat f)"` shows `FAKE-SECRET-abc123` in a world-readable
`cmdline`. This is why nothing is passed as an argument and everything goes
through the environment.

**Three traps worth knowing before editing `mcpProxy.nix`:**

- **`bind <host>` is the ONLY thing that restricts the listener**, and getting
  this wrong is a security bug, not a cosmetic one: a bare `:<port>` site
  address listens on EVERY interface, publishing an unauthenticated endpoint
  while `proxy.host` sits unused and the client entry still claims loopback.
  Writing the host into the SITE ADDRESS instead (`127.0.0.1:9501 { … }`) does
  not fix it and additionally breaks the proxy — in Caddy a site-address host is
  a Host-HEADER matcher, so the listener still covers everything and mismatched
  requests 400. **A string assertion cannot tell these apart**: `127.0.0.1:9501`
  appears in the config either way. Verify with `ss` plus a refused connection
  from a routable address. This repo has shipped the same class of defect before
  in `service.host`.
- **`$${` is a Nix ESCAPE for a literal `${`** in BOTH quoted and indented
  strings. The natural-looking `"{$${var}}"` therefore emits `{${var}}` — no
  substitution, no error, and a Caddyfile that proxies to an unexpanded token.
  The `envRef` helper builds the token by explicit concatenation for exactly
  this reason; do not "simplify" it back into an interpolated string.
- **`reverse_proxy` rejects a PATH in its upstream.** An upstream url may carry
  one, and it may itself be a secret, so it cannot be split at eval time. The
  wrapper splits it in shell at runtime into origin + path and applies the path
  with `rewrite *`. The `case` around that split is load-bearing: with no `/`
  after the host, `${_rest#*/}` returns `_rest` unchanged and the path silently
  becomes the hostname.

It fails CLOSED, deliberately differing from the launcher wrapper below: an
empty or unreadable secret exits 1 naming the variable and the file, rather than
starting a proxy that would answer every client with the upstream's 401.

### Two header surfaces, and which one is which

Since 2026-08-13 the two are SPLIT, and the split is the whole interface:

| Where              | Means                            | May hold a credential? |
| ------------------ | -------------------------------- | ---------------------- |
| `<server>.headers` | what the CLIENT sends            | **no — asserts**       |
| `proxy.headers`    | what the DAEMON injects upstream | yes, that is the point |

`proxy.headers` takes three value shapes: a credential (read from its file at
daemon start and injected), a plain string (injected literally), or **`null`**
(DELETED, so a header the client sent never reaches the upstream).

Before this, `<server>.headers` were ABSORBED into the daemon whenever
`proxy.enable` was set — so one key meant "the client sends this" normally and
"the proxy injects this" when a sibling flag was on. That is reversed. A
credential left in `<server>.headers` on a proxied server is now a hard
assertion naming `proxy.headers`, not an absorption: those headers are written
into the client's config, so passing one through would hand the client the very
credential the proxy exists to withhold. The assertion doubles as the migration
message for config written against the old shape.

**The upstream request is byte-identical to the un-proxied one**, plus the
injected `proxy.headers`. Removing the proxy's own fingerprint is a CORRECTNESS
concern. It took two fixes beyond the obvious one:

- Caddy adds `X-Forwarded-For/Host/Proto` **and `Via: 1.1 Caddy`**. Removing the
  X-Forwarded trio alone leaves `Via` behind — measured, and easy to miss
  because the trio is what everyone thinks of. All four are deleted with
  `header_up -<name>`.
- `Accept-Encoding: gzip` is added by Go's HTTP transport, BELOW the header
  layer, so no `header_up -Accept-Encoding` can remove it. It needs
  `transport http { compression off }`. A header-level fix here looks correct
  and silently does nothing.

Why bother: a proxy-shaped request can trip WAF rules, change how an upstream
derives client identity, and leaks the loopback address and port. It is also one
more thing to rule out when debugging a remote 4xx.

### Masking the CLIENT was tried and REMOVED — do not re-derive it

On 2026-08-12 the proxy also normalized the client: `User-Agent` replaced with
`mcp-client/1.0`, and `Accept-Language` + `Sec-Fetch-Mode` deleted, on the
reasoning that a shared daemon should not tell the upstream which agent harness
is behind it. **It was removed the next day.** The reasoning was wrong in three
independent ways, each measured:

- **Those headers do not identify a harness.** A plain `node -e 'fetch(...)'`
  with no MCP SDK and no harness sends `user-agent: node`, `accept-language: *`,
  `sec-fetch-mode: cors`, `accept-encoding: gzip, deflate` — byte-identical to
  what a live Kiro sent through the proxy. They are undici defaults. **Kiro sets
  no User-Agent at all**, so there is no "Kiro user agent" to leak or to expect.
- **The traffic is identifiable as MCP regardless.** The same requests carry
  `Mcp-Protocol-Version`, which the SDK adds and the transport REQUIRES. It
  cannot be stripped, so masking cannot achieve the goal it was reaching for.
- **Normalizing made the request MORE distinctive, not less.** Traffic that
  looked like any Node process became the only sender emitting `mcp-client/1.0`
  with no `Sec-Fetch-Mode` — a header set no ordinary Node client produces, and
  one that reads as deliberately sanitized.

The MECHANISM survives and costs nothing: `proxy.headers."User-Agent" = "…"` and
`proxy.headers."Accept-Language" = null` are ordinary entries. What was removed
is doing it BY DEFAULT. If a harness ever does start announcing itself (watch
for a `User-Agent` that is not `node`), that is one config line, not a redesign.

`module-mcp-proxy-caddyfile-has-no-secrets` asserts the absence NEGATIVELY, so a
reintroduction has to argue with this section first.

Verified end-to-end 2026-08-12 by running the GENERATED Caddyfile against a
local fake upstream: no `Via`, no `X-Forwarded-*`, the injected credentials
present, and the client's own headers passed through untouched. Also verified:
an upstream URL carrying a path is rewritten correctly, responses streamed
incrementally with compression off, argv clean, and both failure modes loud.

### The journal is a secret sink, and Caddy will not save you

**Caddy's `reverse_proxy` ERROR logs embed the WHOLE request header map**, so
every injected credential lands in the systemd journal in cleartext unless it is
filtered out. Caddy's built-in `log_credentials` (default false) redacts ONLY
`Authorization`, `Cookie`, `Set-Cookie` and `Proxy-Authorization` — and this
proxy injects none of those. It injects CUSTOM auth headers, which are logged
verbatim.

Measured 2026-08-12 on a live pair of units: 35 journal lines carrying a gateway
API key, on a persistent journal, dating to the day the units first started.
This falsified the `Where the secret is, and is not` table above, which listed
environ / argv / Caddyfile / mcp.json and did not contemplate the journal.

The fix drops the **WHOLE HEADER MAP** — `request>headers delete` in Caddy's
`filter` encoder, wrapping console — and never names a secret field.

**That distinction is the point, and the first attempt got it wrong.** The
original fix emitted one `delete` per credential-bearing header. It worked, and
it was still the wrong shape: a per-field list is a DENYLIST, correct only for
the credentials someone remembered to enumerate, and it fails OPEN on anything
new — a header added later, one whose name is computed, or one a future Caddy
starts emitting. Dropping the map fails CLOSED. Measured: a credential header
that no rule mentioned did not appear in the log.

It also deleted an entire sub-problem. The per-field version needed Go's
CANONICAL header casing in the field path, and getting that wrong failed
SILENTLY — `request>headers>X-ACME-API-Key` (the operator's own spelling)
parses, Caddy starts, and the value still reaches the journal; only
`request>headers>X-Acme-Api-Key` redacts. That trap, the canonicalization helper
it required, and the hostile-cased fixture guarding it all stopped existing when
the map went wholesale. **If you are ever tempted back to per-field redaction,
that is the cost.**

The drop is UNCONDITIONAL, even for a proxy injecting no credential. A
conditional would make the safe posture depend on the server's shape, so adding
a credential to an existing server would silently flip logging from safe to
leaky.

**Everything used for debugging survives**: `upstream`, `duration`, `remote_ip`,
`proto`, `method`, `host`, `uri`, and the error. Only headers go.

**Per-server attribution comes from the UNIT, not from a logged header.** There
is one `mcp-proxy-<name>.service` per server, and each sets an explicit
`SyslogIdentifier`. Without it the visible identifier is the ExecStart store
basename — the server name behind a 32-char hash that changes on every rebuild.
`journalctl --user -u mcp-proxy-jira` is how you tell two proxies apart.

**Reproducing the leak needs the right failure.** A dead upstream
(`connection refused`) logs an error with NO headers and reads as "no leak".
Only the mid-stream abort path carries them
(`WARN … aborting with incomplete response`); reproduce it with an SSE upstream
that streams slowly plus a client that disconnects early.

**Still in the journal by design:** the upstream HOST, via the `upstream` and
`request>host` fields — so a `url` marked as a credential still has its hostname
logged. That is deliberate (it is the single most useful field when debugging a
remote 4xx) and is a hostname, not a bearer token, but it is worth knowing
before treating a secret `url` as fully hidden.

SCOPE — Home Manager on Linux only. devenv (process-compose) and Darwin
(launchd) are deferred and **explicitly not WONTFIX**; the devenv transform
asserts rather than dropping the daemon silently.

### Two secret paths, because Kiro treats headers and url differently

VERIFIED against kiro-cli 2.13.0 (binary): `substitute_env_vars` runs over http
**header values** and the stdio env only — the **url field is never passed
through it**. So:

- **Header secret** → rendered into mcp.json as a `<prefix>${env:VAR}<suffix>`
  placeholder. The launcher wrapper (`wrapPackage.nix`) emits an
  `export VAR="$(<coreutils>/bin/cat <file>)"` line — after `envExports`, so a
  secret always wins over a same-named static value — and Kiro substitutes the
  placeholder at launch. mcp.json (placeholder only) is safe to store/commit.
  Collected in `secretEnv`. The `cat` is spelled as an ABSOLUTE coreutils path
  in the emitted line, never bare: this wrapper can be spawned with an empty
  PATH, where a bare `cat` would silently yield an empty credential.
- **URL secret** → Kiro won't expand it, so the literal url must be present when
  Kiro reads mcp.json. It renders to a bare `<prefix>${VAR}<suffix>` sentinel in
  a store TEMPLATE, and WE substitute it with `envsubst` (explicit var list, so
  header `${env:...}` survive) into a REAL private mcp.json at activation.
  Collected in `urlSecretEnv` (kept disjoint from `secretEnv` — different
  mechanism + time; a shared var name throws).

### ⚠ KNOWN LIMITATION — header creds are PER-BINARY, mcp.json is USER-GLOBAL

**A kiro that is not the wrapper carrying the secrets still finds those servers
in the global mcp.json and connects to them with NO credentials.** This is a
scope mismatch in the design, not a defect in any one file.

**It now has a fix — `proxy.enable`, above — but only for servers that OPT IN.**
Everything in this section still applies verbatim to any credential header or
url delivered the `${env:VAR}` way. Read it before adding such a consumer or
"simplifying" the wrapper.

The two halves live at different scopes:

| Half                                           | Where it lives                                        | Scope           |
| ---------------------------------------------- | ----------------------------------------------------- | --------------- |
| Server list + `${env:VAR}` header placeholders | `~/.kiro/settings/mcp.json`                           | **user-global** |
| The credential VALUES                          | `export`s baked into the launcher (`wrapPackage.nix`) | **per-package** |

Nothing ties them together. Any kiro binary that is not the wrapper holding the
secrets reads the same global mcp.json, sees the same servers, and sends the
same headers — with the variables unset.

**The devshell case is the one that bites.** `ai.kiro.enable` in a devenv
project puts a SECOND wrapped kiro on `packages`, which SHADOWS the Home Manager
one on `PATH` inside that shell. That wrapper carries `secretEnv` only for
servers declared in THAT project, so a project that enables kiro without
re-declaring the gateway servers gets a kiro that reads the user-global mcp.json
and authenticates with nothing. Same hazard by other routes: `nix run`, a
nixpkgs `kiro-cli`, or any launch bypassing the wrapper.

The failure is SILENT from the client side — the server list looks right and the
servers are present; only the remote end sees an unauthenticated request.

**NOT measured:** whether Kiro sends an empty header value or the literal
`${env:VAR}` when the variable is unset. Either way no usable credential is
sent; the distinction only changes how the remote end reports it. Do not write
one down as fact without probing it.

**Related, same family:** `wrapPackage.nix` exports each header credential with
`export VAR="$(<coreutils>/bin/cat <file>)"` (absolute, as above). That line's
exit status is `export`'s — always 0 — so an unreadable secret at LAUNCH yields
an empty credential rather than a failure, even under strict mode.
(`mkMcpJsonScript` had the identical idiom for the url and now uses a bare
assignment plus an emptiness guard; the wrapper has NOT been changed, because
failing closed there would refuse to launch kiro at all and that is a product
decision, not a cleanup.)

**The fix direction already exists in this repo — it is
`services.mcp-servers`.** A server in that registry (`serverNames` in
`packages/mcp-services/modules/homeManager/default.nix`) runs as a systemd user
daemon that HOLDS its own credentials, and
`config.services.mcp-servers.mcpConfig.mcpServers` hands clients a
credential-free `{ type = "http"; url = <loopback>; }` entry. The client is
unprivileged, so it does not matter WHICH kiro binary runs — which is exactly
the property the header-placeholder path lacks.

`gitlab-mcp` ships this way and nixos-config runs it today (its daemon stays
enabled while the shared-pool exposure is Kiro-only). Gateway-backed remote
servers are simply NOT on that path: they are raw `type = "http"` entries
pointing at a remote gateway, with auth pushed onto the client. Moving them onto
a local proxy daemon is the design change under consideration, and it is a
nixos-config change plus (for a remote upstream) a proxy that injects headers
rather than the usual "run the server locally" daemon.

Until that lands, do not enable kiro in a devshell on a machine whose gateway
MCP servers come from Home Manager — or declare the same servers and secrets in
the project so its own wrapper carries them.

### Delivery is Kiro-only; other ecosystems throw

`renderServer` throws on a raw credential header/url reaching a non-Kiro path
(Claude/Copilot/Kimchi/shared pool). The Kiro preprocessor resolves credentials
to placeholder strings BEFORE `renderServer`; anything else that sees the raw
attrset fails loud rather than serializing the secret's file path.
(`transformMcpServer` in `ai-common.nix` is DEAD code — every ecosystem renders
via `renderServer`.)

### mcp.json is a real file, governed by `ai.kiro.mcpWriteMode`

mcp.json is NOT a `home.file`/`files` store symlink — it is assembled as a real
file by `mkMcpJsonScript` (HM `home.activation`, devenv `enterShell`), shared so
both backends stay at parity. Uniform real-file delivery is what lets a secret
url land and removes the symlink↔real-file toggle + the devenv `files.*`
silent-skip on a flipped name.

- `overwrite` (default) — re-assemble every activation, `chmod` read-only (0400
  with a secret url, else 0444). Nix-owned; hand edits don't survive.
- `merge` — `jq '.[0] * .[1]'` (Nix wins, write-if-absent), left writeable
  (0600/0644). Hand-added servers/edits survive.

### Gotchas

- A credential url reads its secret at ACTIVATION, so a consumer wiring
  sops-nix/agenix must order the mcp.json activation AFTER the secret provider.
- `--classic` (non-v3) ships the literal header placeholder → failed auth, not a
  leak; the factory wrapper forces `--v3`.
- Static tokens only; rotate = re-export + restart (no refresh hook).

### Deferred (not yet built)

`mcpWriteMode`/merge generalization to Copilot `mcp-config.json`, the settings
files, devenv-merge broadly, and Claude `.mcp.json` (upstream
`programs.claude-code` owns that write into the oauth-bearing `.claude.json`).
Only the Kiro slice ships today.

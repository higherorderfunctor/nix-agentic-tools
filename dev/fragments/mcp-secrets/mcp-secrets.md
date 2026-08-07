## SOPS-Injectable Remote HTTP MCP Servers

> **Last verified:** 2026-08-06 (commit pending — adds the LOCAL
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
> `renderServer` guard, the wrapper export, or the mcp.json writer and this
> fragment isn't updated in the same commit, stop and fix it.

A `type = "http"` MCP server (`ai.mcpServers` / `ai.kiro.mcpServers`) can take
SOPS/agenix-injected `headers` and `url` so secrets never land in the
world-readable store or in committed config. Files:

- `lib/ai/mcpServer/commonSchema.nix` — the (C) http shape; `url` and each
  `headers.<name>` are `secretValue`.
- `lib/ai/mcpServer/secretValue.nix` — `either str credential`
  (`{ file | helper; prefix?; suffix?; var?; }`).
- `lib/mcp.nix` `renderServer` — the shared renderer + non-Kiro throw.
- `packages/kiro-cli/lib/mcpSecrets.nix` — Kiro preprocessor.
- `packages/kiro-cli/lib/mkKiro.nix` — `mkMcpJsonScript` + wiring.
- `packages/kiro-cli/lib/wrapPackage.nix` — `secretEnv` → the runtime `export`
  that puts the decrypted value in the launcher's env.

### The proxy path — `proxy.enable`, and why it is the preferred one

`proxy.enable` on a `type = "http"` server moves the credential OFF the client
entirely. `lib/ai/mcpProxy.nix` renders a Caddy daemon
(`systemd.user.services.mcp-proxy-<name>`) that reads each secret from its file
at START, injects the headers outbound, and listens UNAUTHENTICATED on loopback.
Clients get `{ type = "http"; url = "http://127.0.0.1:<port>/"; }`.

This is not merely a nicer delivery mechanism — it dissolves the scope mismatch
documented below, because **there is no client-side credential left to get
wrong.** It also stops being Kiro-only: `renderServer` throws when a credential
reaches Claude/Copilot/the shared pool, and the proxied entry contains none, so
those ecosystems can consume it.

**Where the secret is, and is not** — the measurement that decides the design:

| Location                  | Mode   | Secret there?                |
| ------------------------- | ------ | ---------------------------- |
| `/proc/<pid>/environ`     | `0400` | yes                          |
| `/proc/<pid>/cmdline`     | `0444` | **never**                    |
| the Caddyfile (Nix store) | `0444` | never — `{$VAR}` tokens only |
| `mcp.json`                | varies | never                        |

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

**The upstream request is byte-identical to the un-proxied one**, plus the
injected credentials and nothing else. That is a deliberate property, not a
happy accident, and it took two fixes beyond the obvious one:

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

Verified end-to-end 2026-08-06 against a local fake upstream, by DIFFING the
header set the upstream received directly against the set it received through
the proxy: the only difference is the three injected credential headers, with
nothing added and nothing dropped. Also verified: an upstream URL carrying a
path is rewritten correctly, responses streamed incrementally with compression
off (four chunks 0.5 s apart, not buffered), argv clean, and both failure modes
loud.

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

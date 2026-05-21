# gitlab-mcp Packaging (slim)

Package `zereight/gitlab-mcp` (npm `@zereight/mcp-gitlab`) as a Node-based
MCP server. This follows the standard recipe — the only non-routine bit is
the self-hosted GitLab URL, which may need to be treated as a credential.

## Frozen facts

| Item              | Value                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------- |
| Repo              | `github.com/zereight/gitlab-mcp`                                                       |
| Tag / rev         | `v2.1.13` → `c2577169b21d62197f767895fe97651ffb2d7443` (already pinned in overlay)     |
| License           | MIT                                                                                    |
| Build             | `npm run build` (tsc → `build/index.js`)                                               |
| Entry binary      | `mcp-gitlab` (we rename to `gitlab-mcp` via `makeWrapper`)                             |
| Runtime           | `bun` (repo convention — upstream allows node ≥18 but we standardize on bun)           |
| Native deps       | none                                                                                   |
| Tool count        | 182 (verified upstream — see "Upstream verification" at end)                           |
| Reserved port     | `19761`                                                                                |
| Templates to copy | `overlays/mcp-servers/git-intel-mcp.nix`, `packages/github-mcp/modules/mcp-server.nix` |

Ports already used: 19750 (context7), 19751 (github), 19752 (nixos),
19753 (kagi), 19754 (effect), 19755 (fetch), 19756 (git-intel), 19757 (git),
19758 (openmemory), 19759 (sequential-thinking), 19760 (sympy).

## Design

### Credentials (flat keys on `settings`)

`lib/mcp.nix` looks up `settings.${optName}` from the `credentialVars`
key, so credential options must be flat.

| Key        | Env var                        | Required | Upstream                                                                                                                                            |
| ---------- | ------------------------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pat`      | `GITLAB_PERSONAL_ACCESS_TOKEN` | yes      | [`config.ts:32`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L32)                                |
| `apiUrl`   | `GITLAB_API_URL`               | no       | [`index.ts:791,1411`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L791-L791) (read via getConfig) |
| `jobToken` | `GITLAB_JOB_TOKEN`             | no       | [`config.ts:33`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L33)                                |

Each is `mcpLib.mkCredentialsOption ENVVAR` — the existing `attrTag
{ file; helper; }` schema. No extension needed.

**On the naming divergence from github-mcp** (approved 2026-05-20):
github-mcp groups its single secret under a generic `credentials.*`
umbrella; gitlab-mcp uses three flat named keys (`pat`, `apiUrl`,
`jobToken`) because each describes a distinct credential whose
purpose is meaningful to the consumer. Normalizing all MCP modules
to a unified credential schema is a separate, deferred design — do
not "fix" this divergence in passing.

### Self-hosted URL — the one tricky bit

Two ways to point at a non-default instance, mutually exclusive:

- `settings.instanceUrl` — plain `nullOr str`, lands in the Nix store.
  Flows to `GITLAB_API_URL` via `settingsToEnv`.
- `settings.apiUrl.file` / `.helper` — keeps the URL out of the store.
  Flows through the credential pipeline at exec time.

`evalSettings` discards `eval.assertions` (see `lib/mcp.nix:27-37`), so a
module-level `assertions` block silently no-ops. Encode the mutex as an
`if/throw` at the top of `settingsToEnv` — it fires every time
`renderServer` evaluates the config:

```nix
settingsToEnv = cfg: _mode: let
  s = cfg.settings;
  instanceUrlSet = s.instanceUrl != null;
  apiUrlCredSet =
    (s.apiUrl.file or null) != null
    || (s.apiUrl.helper or null) != null;
in
  if instanceUrlSet && apiUrlCredSet
  then throw ''
    gitlab-mcp: set either `settings.instanceUrl` (plain URL, in Nix
    store) or `settings.apiUrl.file`/`helper` (kept out of store) — not
    both.''
  else /* optionalAttrs merge for the typed options below */;
```

### Typed options (v1)

| Option              | Env                          | Type                        | Default | Upstream                                                                                                                          |
| ------------------- | ---------------------------- | --------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `instanceUrl`       | `GITLAB_API_URL`             | `nullOr str`                | `null`  | [`index.ts:1411`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L1411)            |
| `caCertPath`        | `GITLAB_CA_CERT_PATH`        | `nullOr str`                | `null`  | [`config.ts:209`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L209)            |
| `defaultProjectId`  | `GITLAB_PROJECT_ID`          | `nullOr str`                | `null`  | [`index.ts:1415`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L1415)            |
| `allowedProjectIds` | `GITLAB_ALLOWED_PROJECT_IDS` | `listOf str` (joined `,`)   | `[]`    | [`index.ts:1416-1417`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L1416-L1417) |
| `readOnly`          | `GITLAB_READ_ONLY_MODE`      | `bool` (emit `"true"` only) | `false` | [`config.ts:42`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L42)              |
| `toolsets`          | `GITLAB_TOOLSETS`            | `listOf str` (joined `,`)   | `[]`    | [`config.ts:51`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L51)              |
| `tools`             | `GITLAB_TOOLS`               | `listOf str` (joined `,`)   | `[]`    | [`config.ts:52`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L52)              |
| `deniedToolsRegex`  | `GITLAB_DENIED_TOOLS_REGEX`  | `nullOr str`                | `null`  | [`index.ts:997-998`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L997-L998)     |
| `useWiki`           | `USE_GITLAB_WIKI`            | `bool` (emit `"true"` only) | `false` | [`config.ts:43`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L43)              |
| `useMilestone`      | `USE_MILESTONE`              | `bool` (emit `"true"` only) | `false` | [`config.ts:44`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L44)              |
| `usePipeline`       | `USE_PIPELINE`               | `bool` (emit `"true"` only) | `false` | [`config.ts:45`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L45)              |

Use `types.listOf types.str` for `tools` — **do not** build a 182-entry
`types.enum`. `meta.tools` lists names for discovery; the option itself
stays freeform.

Transport: stdio only. `meta.modes.http = "bridge"` (use `mcp-proxy`),
matching every other MCP in this repo.

OAuth (`GITLAB_USE_OAUTH`, `GITLAB_MCP_OAUTH`, etc.) is out of v1 scope —
consumers who need it use the freeform `env = { … }` escape hatch.

### Deferred env vars

Upstream reads these but v1 doesn't surface them as typed options.
Consumers who need them use the freeform `env = { … }` escape hatch.

| Env var                                   | Upstream                                                                                                                        | Reason deferred                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `GITLAB_AUTH_COOKIE_PATH`                 | [`config.ts:34`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L34)            | Niche auth path (cookie-based)                                                               |
| `GITLAB_IS_OLD`                           | [`config.ts:36`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L36)            | Compatibility flag for old GitLab versions                                                   |
| `GITLAB_TOOL_POLICY_APPROVE`              | [`config.ts:56-58`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L56-L58)     | Fine-grained policy; revisit once consumers ask                                              |
| `GITLAB_TOOL_POLICY_HIDDEN`               | [`config.ts:60-62`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L60-L62)     | Fine-grained policy; revisit once consumers ask                                              |
| `SSE` / `STREAMABLE_HTTP`                 | [`config.ts:69-70`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L69-L70)     | Native HTTP/SSE transport — we use `mcp-proxy` bridge instead                                |
| `REMOTE_AUTHORIZATION`                    | [`config.ts:71`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L71)            | Part of OAuth surface                                                                        |
| `ENABLE_DYNAMIC_API_URL`                  | [`config.ts:87-88`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L87-L88)     | Per-session API URL routing; OAuth-adjacent                                                  |
| `OAUTH_STATELESS_*` (5 vars)              | [`config.ts:96,141-186`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L96)    | OAuth out of scope                                                                           |
| `MCP_SERVER_URL`                          | [`config.ts:78`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L78)            | OAuth out of scope                                                                           |
| `GITLAB_OAUTH_APP_ID`                     | [`config.ts:79`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L79)            | OAuth out of scope                                                                           |
| `GITLAB_OAUTH_SCOPES`                     | [`config.ts:80`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L80)            | OAuth out of scope                                                                           |
| `GITLAB_OAUTH_CALLBACK_PROXY`             | [`config.ts:85`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L85)            | OAuth out of scope                                                                           |
| `SESSION_TIMEOUT_SECONDS`                 | [`config.ts:171`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L171)          | Server tuning; defaults are fine                                                             |
| `HOST` / `PORT`                           | [`config.ts:192,196`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L192)      | HTTP-mode only — bridged through mcp-proxy                                                   |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | [`config.ts:202-204`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L202-L204) | Standard env names — picked up from process env via `env = {}` escape hatch                  |
| `NODE_TLS_REJECT_UNAUTHORIZED`            | [`config.ts:205`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L205)          | Standard Node flag; rarely set                                                               |
| `GITLAB_POOL_MAX_SIZE`                    | [`config.ts:211`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L211)          | Connection-pool tuning; default 100 is fine                                                  |
| `GITLAB_GRAPHQL_URL`                      | [`index.ts:1934`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L1934)          | Auto-derived from `GITLAB_API_URL`; only override if hosting GraphQL on a non-default origin |

## Files

### Create

- `overlays/mcp-servers/gitlab-mcp.nix` — copy `git-intel-mcp.nix`, swap:
  - `rev`, `hash`, `npmDepsHash` (two fakeHash rounds)
  - owner/repo/pname → `zereight` / `gitlab-mcp` / `gitlab-mcp`
  - `upstream = "2.1.13"` (or current `package.json` value at land time)
  - `build/index.js` path (upstream emits `build/`, not `dist/`)
  - wrapper binary name `gitlab-mcp` (keep `bun` as the runtime — repo
    convention, matches git-intel-mcp's `makeWrapper ${bun}/bin/bun ...`)
  - drop the `git`/`vitest` check inputs and `checkPhase` (gitlab-mcp's
    upstream tests aren't run here; git-intel runs vitest)
  - `meta.{license = ourPkgs.lib.licenses.mit; mainProgram = "gitlab-mcp"; homepage; description}`
- `packages/gitlab-mcp/default.nix` — barrel, 5 lines like `github-mcp/default.nix`
- `packages/gitlab-mcp/modules/mcp-server.nix` — typed schema (see Design above)
- `packages/gitlab-mcp/lib/mkGitlab.nix` — rename of `github-mcp/lib/mkGitHub.nix`.
  Stub with `options = {}`. **Intentionally mirrors the existing
  pattern** so when the factory-factory DRY gap
  (`project_factory_known_gaps.md`) gets fixed, gitlab-mcp moves with the
  rest of the cohort in one sweep instead of needing a separate catch-up.
- `packages/gitlab-mcp/docs/README.md` — short usage doc covering:
  - sops-nix PAT wiring
  - `instanceUrl` vs `apiUrl.file` (when to pick which)
  - the `readOnly` / `toolsets` / `deniedToolsRegex` knobs for trust posture
  - reference to upstream tool list (don't embed 182 entries inline)

### Register (alphabetical inserts between `github-mcp` and `kagi-mcp`)

1. `overlays/default.nix` (~line 82)
2. `packages/default.nix`
3. `config/update-matrix.nix` — entry with `flags = "--version skip"` and `git = "https://github.com/zereight/gitlab-mcp.git"`
4. `dev/data.nix` — `{ description = "GitLab platform integration"; credentials = "Required"; }`
5. `packages/mcp-services/modules/homeManager/default.nix:52` — add `"gitlab-mcp"` to names list
6. `checks/cache-hit-parity.nix:99` — add `"gitlab-mcp"` to package list
7. `checks/factory-eval.nix:213` — add two tests after `github-mcp`'s:
   - `factory-loadServer-gitlab-mcp-from-package-dir` (checks `settingsOptions ? pat`)
   - `factory-gitlab-mcp-has-package-module`
8. `checks/module-eval.nix:1214` — add `&& servers ? gitlab-mcp`
9. `config/cspell/project-terms.txt` — add `glpat`, `mcpgitlab`, `zereight` if absent (alphabetical)

**Do NOT edit `README.md` directly.** It is generated. `dev/generate.nix:513`
emits the server count (`${toString mcpServerCount} servers`) from the
`dev/data.nix` attrset size, and the table rows come from
`mcpServerMeta`. After registering in `dev/data.nix` (step 4), run:

```bash
devenv tasks run --mode before generate:repo
```

That regenerates `README.md` with the new count and row in one shot. Any
manual edit to `README.md:128` will be clobbered the next time anyone
runs the generator.

## Validation

```bash
nix build .#ai.mcpServers.gitlab-mcp
devenv tasks run --mode before generate:repo   # regenerate README
nix flake check
treefmt
```

Smoke test runs automatically via `vu.mkMcpSmokeTest` in `installCheckPhase`.

## Hash bootstrap

1. Set `src.hash` and `npmDepsHash` to `ourPkgs.lib.fakeHash`.
2. `nix build .#ai.mcpServers.gitlab-mcp` → copy `got: sha256-…` from
   the first failure into `src.hash`.
3. Rebuild → copy the second `got:` into `npmDepsHash`.
4. Rebuild → should succeed.

If a third real hash appears, something is off (wrong rev, upstream
retagged, postUnpack needed) — stop and look at the build error.

## Commits

Small linear commits, restack later as needed:

1. `feat(overlay): add gitlab-mcp package` — `overlays/mcp-servers/gitlab-mcp.nix` + `overlays/default.nix`
2. `feat(gitlab-mcp): typed server module and factory stub` — `packages/gitlab-mcp/{default.nix,modules/,lib/}`
3. `feat(gitlab-mcp): register across monorepo` — registration touchpoints +
   `devenv tasks run --mode before generate:repo` output (regenerated README)
4. `docs(gitlab-mcp): consumer config` — `packages/gitlab-mcp/docs/README.md`

Only the final state must pass `nix flake check`.

## Don'ts (would cause a fresh implementer to drift)

- **No nvfetcher.** Source-built packages in this repo use inline rev+hash; `nix-update` handles bumps.
- **No `sourceRoot` / `postUnpack`.** Upstream is a single-package repo, not a workspace.
- **No `dist/`.** Upstream emits to `build/`.
- **No 182-entry `types.enum`.** Use `listOf str`. `meta.tools` is a discovery list, not a type constraint.
- **No `meta.external = true`.** That's for servers hosted as remote HTTP services; gitlab-mcp is a local stdio server with a runtime-configurable upstream.
- **No literal-value tag on `mkCredentialsOption`.** PAT must stay file/helper-only so it can't accidentally land in the store. The `instanceUrl` plain-string option is declared separately at the module level.
- **No `final.X`** for build inputs — only `final.stdenv.hostPlatform.system`. Everything else routes through `ourPkgs` for cache-hit parity.
- **`passthru` merges, never replaces** — `(old.passthru or {}) // { … }`.

## Upstream verification

- Tool list: extracted 2026-05-20 from
  [`tools/registry.ts:194-1124`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/tools/registry.ts#L194-L1124),
  **182 tools total** (verified via
  `awk '/^export const allTools = \[/,/^];$/' tools/registry.ts | grep -E '^\s+name:' | wc -l`).
  Read-only set: 102 tools in
  [`tools/registry.ts:1127-1230`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/tools/registry.ts#L1127-L1230).
  Destructive set: 21 tools in
  [`tools/registry.ts:1233-1255`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/tools/registry.ts#L1233-L1255).
  (Earlier draft asserted 154 — wrong; corrected after counting v2.1.13.)
- Env var registry: scanned 2026-05-20 from
  [`config.ts:32-211`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L32-L211)
  plus the four env reads that live in
  [`index.ts:791,997,1411,1415-1417`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L791)
  (`GITLAB_API_URL`, `GITLAB_DENIED_TOOLS_REGEX`, `GITLAB_PROJECT_ID`,
  `GITLAB_ALLOWED_PROJECT_IDS`). All 13 env var names claimed in
  "Typed options (v1)" and "Credentials" verified against upstream.
- Pinned commit: `c2577169b21d62197f767895fe97651ffb2d7443` (v2.1.13).
- Best-judgment notes:
  - The deferred-vars table lists `OAUTH_STATELESS_*` collectively
    pointing at config.ts:96; the five constants span
    [`config.ts:96,141,146,151,185`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L96)
    — collapsed to keep the table readable since the entire group is
    OAuth-out-of-scope.
  - `caCertPath` (`GITLAB_CA_CERT_PATH`) is read in config.ts at line 209,
    but the consuming code path (HTTPS agent wiring) was not traced —
    flag for impl-time verification that emitting the env var actually
    affects the running server (a quick smoke test with a self-signed
    cert is enough).
  - The mutex `throw` in `settingsToEnv` is deliberately not unit-tested
    at plan time per user direction — verify behavior during
    implementation by attempting a conflicting config and watching
    `nix eval` surface the message.
  - `GITLAB_GRAPHQL_URL` (`index.ts:1934`) is technically a `process.env`
    direct read rather than going through `getConfig` — no CLI flag
    equivalent. Listed as deferred since it's auto-derived from
    `GITLAB_API_URL` in the normal case.

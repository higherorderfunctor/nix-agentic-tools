# gitlab-mcp Packaging (slim)

Package `zereight/gitlab-mcp` (npm `@zereight/mcp-gitlab`) as a Node-based
MCP server. This follows the standard recipe — the only non-routine bit is
the self-hosted GitLab URL, which may need to be treated as a credential.

## Frozen facts

| Item              | Value                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------- |
| Repo              | `github.com/zereight/gitlab-mcp`                                                       |
| Tag / rev         | `v2.1.11` / `3c8a1f367902ba10a2a01e93c86bd68d7a08996a`                                 |
| License           | MIT                                                                                    |
| Build             | `npm run build` (tsc → `build/index.js`)                                               |
| Entry binary      | `mcp-gitlab` (we rename to `gitlab-mcp`)                                               |
| Native deps       | none                                                                                   |
| Reserved port     | `19761`                                                                                |
| Templates to copy | `overlays/mcp-servers/git-intel-mcp.nix`, `packages/github-mcp/modules/mcp-server.nix` |

Ports already used: 19750 (context7), 19751 (github), 19752 (nixos),
19753 (kagi), 19754 (effect), 19755 (fetch), 19756 (git-intel), 19757 (git),
19758 (openmemory), 19759 (sequential-thinking), 19760 (sympy).

## Design

### Credentials (flat keys on `settings`)

`lib/mcp.nix` looks up `settings.${optName}` from the `credentialVars`
key, so credential options must be flat.

| Key        | Env var                        | Required |
| ---------- | ------------------------------ | -------- |
| `pat`      | `GITLAB_PERSONAL_ACCESS_TOKEN` | yes      |
| `apiUrl`   | `GITLAB_API_URL`               | no       |
| `jobToken` | `GITLAB_JOB_TOKEN`             | no       |

Each is `mcpLib.mkCredentialsOption ENVVAR` — the existing `attrTag
{ file; helper; }` schema. No extension needed.

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

| Option              | Env                          | Type                        | Default |
| ------------------- | ---------------------------- | --------------------------- | ------- |
| `instanceUrl`       | `GITLAB_API_URL`             | `nullOr str`                | `null`  |
| `caCertPath`        | `GITLAB_CA_CERT_PATH`        | `nullOr str`                | `null`  |
| `defaultProjectId`  | `GITLAB_PROJECT_ID`          | `nullOr str`                | `null`  |
| `allowedProjectIds` | `GITLAB_ALLOWED_PROJECT_IDS` | `listOf str` (joined `,`)   | `[]`    |
| `readOnly`          | `GITLAB_READ_ONLY_MODE`      | `bool` (emit `"true"` only) | `false` |
| `toolsets`          | `GITLAB_TOOLSETS`            | `listOf str` (joined `,`)   | `[]`    |
| `tools`             | `GITLAB_TOOLS`               | `listOf str` (joined `,`)   | `[]`    |
| `deniedToolsRegex`  | `GITLAB_DENIED_TOOLS_REGEX`  | `nullOr str`                | `null`  |
| `useWiki`           | `USE_GITLAB_WIKI`            | `bool` (emit `"true"` only) | `false` |
| `useMilestone`      | `USE_MILESTONE`              | `bool` (emit `"true"` only) | `false` |
| `usePipeline`       | `USE_PIPELINE`               | `bool` (emit `"true"` only) | `false` |

Use `types.listOf types.str` for `tools` — **do not** build a 154-entry
`types.enum`. `meta.tools` lists names for discovery; the option itself
stays freeform.

Transport: stdio only. `meta.modes.http = "bridge"` (use `mcp-proxy`),
matching every other MCP in this repo.

OAuth (`GITLAB_USE_OAUTH`, `GITLAB_MCP_OAUTH`, etc.) is out of v1 scope —
consumers who need it use the freeform `env = { … }` escape hatch.

## Files

### Create

- `overlays/mcp-servers/gitlab-mcp.nix` — copy `git-intel-mcp.nix`, swap:
  - `rev`, `hash`, `npmDepsHash` (two fakeHash rounds)
  - owner/repo/pname → `zereight` / `gitlab-mcp` / `gitlab-mcp`
  - `upstream = "2.1.11"`
  - `build/index.js` path (upstream emits `build/`, not `dist/`)
  - wrapper binary name `gitlab-mcp`
  - drop the `git`/`vitest` check inputs and `checkPhase` (gitlab-mcp's
    upstream tests aren't run here; git-intel runs vitest)
  - `meta.{license = ourPkgs.lib.licenses.mit; mainProgram = "gitlab-mcp"; homepage; description}`
- `packages/gitlab-mcp/default.nix` — barrel, 5 lines like `github-mcp/default.nix`
- `packages/gitlab-mcp/modules/mcp-server.nix` — typed schema (see Design above)
- `packages/gitlab-mcp/lib/mkGitlab.nix` — rename of `github-mcp/lib/mkGitHub.nix`
- `packages/gitlab-mcp/docs/README.md` — short usage doc covering:
  - sops-nix PAT wiring
  - `instanceUrl` vs `apiUrl.file` (when to pick which)
  - the `readOnly` / `toolsets` / `deniedToolsRegex` knobs for trust posture
  - reference to upstream tool list (don't embed 154 entries inline)

### Register (alphabetical inserts between `github-mcp` and `kagi-mcp`)

1. `overlays/default.nix` (~line 82)
2. `packages/default.nix`
3. `config/update-matrix.nix` — entry with `flags = "--version skip"` and `git = "https://github.com/zereight/gitlab-mcp.git"`
4. `dev/data.nix` — `{ description = "GitLab platform integration"; credentials = "Required"; }`
5. `README.md:128` — bump server count `14 → 15`, add table row
6. `packages/mcp-services/modules/homeManager/default.nix:52` — add `"gitlab-mcp"` to names list
7. `checks/cache-hit-parity.nix:99` — add `"gitlab-mcp"` to package list
8. `checks/factory-eval.nix:213` — add two tests after `github-mcp`'s:
   - `factory-loadServer-gitlab-mcp-from-package-dir` (checks `settingsOptions ? pat`)
   - `factory-gitlab-mcp-has-package-module`
9. `checks/module-eval.nix:1214` — add `&& servers ? gitlab-mcp`
10. `config/cspell/project-terms.txt` — add `glpat`, `mcpgitlab`, `zereight` if absent (alphabetical)

## Validation

```bash
nix build .#ai.mcpServers.gitlab-mcp
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
2. `feat(gitlab-mcp): typed server module and factory` — `packages/gitlab-mcp/{default.nix,modules/,lib/}`
3. `feat(gitlab-mcp): register across monorepo` — all the registration touchpoints
4. `docs(gitlab-mcp): consumer config` — `packages/gitlab-mcp/docs/README.md`

Only the final state must pass `nix flake check`.

## Don'ts (would cause a fresh implementer to drift)

- **No nvfetcher.** Source-built packages in this repo use inline rev+hash; `nix-update` handles bumps.
- **No `sourceRoot` / `postUnpack`.** Upstream is a single-package repo, not a workspace.
- **No `dist/`.** Upstream emits to `build/`.
- **No 154-entry `types.enum`.** Use `listOf str`. `meta.tools` is a discovery list, not a type constraint.
- **No `meta.external = true`.** That's for servers hosted as remote HTTP services; gitlab-mcp is a local stdio server with a runtime-configurable upstream.
- **No literal-value tag on `mkCredentialsOption`.** PAT must stay file/helper-only so it can't accidentally land in the store. The `instanceUrl` plain-string option is declared separately at the module level.
- **No `final.X`** for build inputs — only `final.stdenv.hostPlatform.system`. Everything else routes through `ourPkgs` for cache-hit parity.
- **`passthru` merges, never replaces** — `(old.passthru or {}) // { … }`.

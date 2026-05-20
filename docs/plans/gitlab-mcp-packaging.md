# gitlab-mcp Packaging Plan

Implementation plan for adding `zereight/gitlab-mcp` to this monorepo. All
upstream research and design decisions are frozen below. The implementing
session does no discovery — it executes phases sequentially with a HITL gate
between each.

## Goal

Package `github.com/zereight/gitlab-mcp` (npm `@zereight/mcp-gitlab`) as a
Node-based MCP server using the standard monorepo template. Output: a working
`pkgs.ai.mcpServers.gitlab-mcp` derivation plus the typed server module and
all registration entries, fanned out automatically to Claude / Copilot / Kiro
through the existing factory.

## Upstream facts (frozen)

| Item                   | Value                                                     |
| ---------------------- | --------------------------------------------------------- |
| Repo                   | `github.com/zereight/gitlab-mcp`                          |
| Tag                    | `v2.1.11`                                                 |
| Commit SHA             | `3c8a1f367902ba10a2a01e93c86bd68d7a08996a`                |
| License                | MIT                                                       |
| Build tool             | npm (no pnpm)                                             |
| Build step             | `npm run build` runs `tsc` (no pre-built `build/` in git) |
| Entry binary           | `mcp-gitlab` → `build/index.js`                           |
| Engine                 | `node >=18`                                               |
| Runtime in our wrapper | `bun` (same as every other Node MCP in this repo)         |
| Transport modes        | stdio (default), SSE, Streamable HTTP — all native        |
| Native deps            | none (pure JS)                                            |

## Design decisions (frozen)

### Self-hosted GitLab URL

Two options on the typed schema (per (A) from the design discussion):

- `instanceUrl` — `nullOr str`, plain typed config, flows through
  `settingsToEnv` → `GITLAB_API_URL`. Use when the URL is OK to land in the
  Nix store.
- `apiUrl` (file/helper credential via `mcpLib.mkCredentialsOption`) — use
  when the URL must be kept out of the Nix store (encrypted at rest, e.g.
  sops). Resolved at exec time by `mkSecretsWrapper`.

Module-level assertion: `instanceUrl != null && apiUrl (file or helper) set`
fails eval with a message instructing the user to pick one. PAT has only the
file/helper schema — no literal path exists.

### Credentials surface (v1)

Three credentials, **flat keys** (the credential pipeline in `lib/mcp.nix:104`
looks up `settings.${optName}` so keys must be top-level on `settings`):

- `settings.pat` — `GITLAB_PERSONAL_ACCESS_TOKEN`, required.
- `settings.apiUrl` — `GITLAB_API_URL`, optional (URL-from-file form).
- `settings.jobToken` — `GITLAB_JOB_TOKEN`, optional (alternate auth).

Each is an `mcpLib.mkCredentialsOption` (the `attrTag { file; helper; }`
discriminated union — exactly one of `file` or `helper`, wrapped in `nullOr`,
default `null`).

OAuth-related env vars (`GITLAB_USE_OAUTH`, `GITLAB_MCP_OAUTH`, stateless mode,
etc.) are **out of v1 scope**. The escape hatch is the standard `env = { … }`
freeform passthrough on `mkStdioEntry` — consumers who need OAuth set those
env vars directly.

### Conflict assertion (instanceUrl vs apiUrl)

`evalSettings` in `lib/mcp.nix:27-37` discards `eval.assertions`, so
module-level assertions silently no-op. None of the existing mcp-server
modules use assertions. Encode the constraint as `if/throw` at the top of
`settingsToEnv` — that function is called every time `renderServer` runs
(`lib/mcp.nix:203` → `effectiveEnv`), so the throw fires whenever a consumer
evaluates the config:

```nix
settingsToEnv = cfg: _mode: let
  instanceUrlSet = cfg.settings.instanceUrl != null;
  apiUrlCredSet =
    (cfg.settings.apiUrl.file or null) != null
    || (cfg.settings.apiUrl.helper or null) != null;
in
  if instanceUrlSet && apiUrlCredSet
  then
    throw ''
      gitlab-mcp: cannot set both `settings.instanceUrl` (literal URL)
      and `settings.apiUrl` (file/helper credential). Pick one — use
      `instanceUrl` for plain config, or `apiUrl.file` to keep the URL
      out of the Nix store (sops/agenix).''
  else
    /* the optionalAttrs merge for typed-option env vars */;
```

### Typed feature options (v1)

| Module option       | Env var                      | Type                         | Default |
| ------------------- | ---------------------------- | ---------------------------- | ------- |
| `instanceUrl`       | `GITLAB_API_URL`             | `nullOr str`                 | `null`  |
| `caCertPath`        | `GITLAB_CA_CERT_PATH`        | `nullOr str`                 | `null`  |
| `defaultProjectId`  | `GITLAB_PROJECT_ID`          | `nullOr str`                 | `null`  |
| `allowedProjectIds` | `GITLAB_ALLOWED_PROJECT_IDS` | `listOf str` (joined by `,`) | `[]`    |
| `readOnly`          | `GITLAB_READ_ONLY_MODE`      | `bool`                       | `false` |
| `toolsets`          | `GITLAB_TOOLSETS`            | `listOf str` (joined by `,`) | `[]`    |
| `tools`             | `GITLAB_TOOLS`               | `listOf str` (joined by `,`) | `[]`    |
| `deniedToolsRegex`  | `GITLAB_DENIED_TOOLS_REGEX`  | `nullOr str`                 | `null`  |
| `useWiki`           | `USE_GITLAB_WIKI`            | `bool`                       | `false` |
| `useMilestone`      | `USE_MILESTONE`              | `bool`                       | `false` |
| `usePipeline`       | `USE_PIPELINE`               | `bool`                       | `false` |

Bool envs go out as the literal string `"true"` only when the option is `true`,
omitted when `false`. List envs join with `,` and are omitted when empty.

### Transport

Upstream supports stdio, SSE, and Streamable HTTP natively. v1 ships stdio
only — HTTP mode is `"bridge"` (use `mcp-proxy`) until a consumer asks for
native HTTP. Rationale: matches every other MCP in this repo; native HTTP
adds an `STREAMABLE_HTTP=true` env knob + port wiring that nothing currently
exercises.

### Tool taxonomy

154 tools total. The `meta.tools` list mirrors the full upstream list (the
implementing session embeds it verbatim from §A2 below). Read vs write split
is documented in `packages/gitlab-mcp/docs/README.md` for consumers building
their `trustedMcpTools` lists.

### Reserved port

`defaultPort = 19761`. Used ports: 19750 (context7), 19751 (github), 19752
(nixos), 19753 (kagi), 19754 (effect), 19755 (fetch), 19756 (git-intel),
19757 (git), 19758 (openmemory), 19759 (sequential-thinking), 19760 (sympy).

### Template reference

Closest match: `overlays/mcp-servers/git-intel-mcp.nix` (single-package npm
repo, single binary, source-built via tsc, no monorepo workspace). Do NOT
copy `openmemory-mcp.nix` — it has `sourceRoot` + `postUnpack` for a workspace
which this package doesn't need.

### Commit shape

Small linear commits per phase. Restack later as needed — no `/stack-*` skill
usage required for this work.

## Orchestration model

Supervisor-worker-verifier with HITL gates between phases.

```
┌──────────────────────────────────────────────────────────┐
│ Supervisor (the implementing session's main agent)       │
│  - Reads this plan                                       │
│  - Owns TaskCreate / TaskUpdate                          │
│  - Dispatches one phase at a time                        │
│  - Surfaces verifier output to HITL between phases       │
│  - Does NOT make design decisions — they're frozen here  │
└──┬───────────────────────────────────────────────────────┘
   │
   │ dispatch worker (write-capable)
   ▼
┌──────────────────────────────────────────────────────────┐
│ Worker subagent (subagent_type = general-purpose)        │
│  - Executes one phase                                    │
│  - Returns: list of files changed, exit-status summary   │
│  - Does NOT improvise — escalates per phase's            │
│    failure-mode taxonomy                                 │
└──┬───────────────────────────────────────────────────────┘
   │ returns summary
   ▼
┌──────────────────────────────────────────────────────────┐
│ Verifier subagent (subagent_type = Explore)              │
│  - Read-only checks per phase                            │
│  - Returns: pass/fail per criterion + evidence           │
└──┬───────────────────────────────────────────────────────┘
   │ verifier output
   ▼
┌──────────────────────────────────────────────────────────┐
│ Supervisor → HITL: post diff summary + verifier output   │
│   - HITL approves → dispatch next phase                  │
│   - HITL pivots → supervisor adjusts and re-dispatches   │
└──────────────────────────────────────────────────────────┘
```

### Rules for the supervisor

1. **No two phases dispatched without a HITL approval between them.**
2. **No improvising past the plan.** If a verifier reports a failure mode
   not enumerated below, escalate to HITL — do not have the worker retry
   blindly.
3. **TaskCreate / TaskUpdate** for cross-phase state. One task per phase;
   mark `in_progress` at dispatch, `completed` after HITL approval, never
   batch.
4. **Diff summary to HITL** = `git diff --stat` plus the first ~40 lines of
   `git diff` per file. Don't dump the entire diff inline.
5. **Verifier prompts are read-only.** They run `nix build`, `nix flake
check`, `grep`, file-existence checks. They do not modify files.

### Rules for workers

1. **Self-contained prompts.** Each worker prompt below stands alone — the
   worker does not need to read prior phase outputs except for the file
   list the supervisor passes through.
2. **Failure escalation.** When a documented failure mode trips, the worker
   reports it back with the classification token (e.g.
   `[hash-mismatch round-1]`) — does NOT retry beyond the budget specified
   in the phase.
3. **No skill invocation inside the worker** unless this plan tells it to.
   Skills can pull in patterns that conflict with the frozen design.
4. **Absolute paths in shell wrappers.** `${pkgs.coreutils}/bin/cat`, never
   bare `cat`. Bash strict mode (`set -euETo pipefail; shopt -s
inherit_errexit`). These are non-negotiable repo rules.

### Rules for verifiers

1. **Read-only.** Tools restricted to Explore's set (no Edit, no Write).
2. **Evidence per claim.** Every pass/fail line cites a file path + line
   number or a command's exit status. No vibes.
3. **Stop at first hard failure.** No need to run later checks once an
   earlier criterion failed — report and return.

## Phases

### Phase 1 — Overlay package builds

**Goal:** `nix build .#ai.mcpServers.gitlab-mcp` succeeds.

**Files touched:**

- `overlays/mcp-servers/gitlab-mcp.nix` (new)
- `overlays/default.nix` (one insertion)

**Worker prompt:**

```
You are implementing Phase 1 of docs/plans/gitlab-mcp-packaging.md in the
nix-agentic-tools-ideation monorepo. Goal: package overlays/mcp-servers/
gitlab-mcp.nix builds successfully.

Use git-intel-mcp.nix as your template:

  Read: /home/caubut/Documents/projects/nix-agentic-tools-ideation/overlays/mcp-servers/git-intel-mcp.nix

Create overlays/mcp-servers/gitlab-mcp.nix with these frozen values:

  - rev = "3c8a1f367902ba10a2a01e93c86bd68d7a08996a"  (v2.1.11)
  - upstream version = "2.1.11"
  - owner = "zereight"
  - repo = "gitlab-mcp"
  - pname = "gitlab-mcp"
  - meta.mainProgram = "gitlab-mcp"
  - meta.license = ourPkgs.lib.licenses.mit
  - meta.description = "MCP server for GitLab platform integration"
  - meta.homepage = "https://github.com/zereight/gitlab-mcp"
  - The wrapper script runs $out/lib/gitlab-mcp/build/index.js (NOT dist/ —
    upstream emits to build/, not dist/).
  - Single binary named "gitlab-mcp" wrapping the upstream "mcp-gitlab"
    entry (we rename via makeWrapper).
  - Use bun as the runtime: makeWrapper ${bun}/bin/bun $out/bin/gitlab-mcp
      --add-flags "$out/lib/gitlab-mcp/build/index.js"
  - installCheckPhase = vu.mkMcpSmokeTest { bin = "gitlab-mcp"; }
  - doInstallCheck = true

Hash bootstrap procedure (two hashes to discover):

  1. Set both src.hash and npmDepsHash to ourPkgs.lib.fakeHash.
  2. Run: nix build .#ai.mcpServers.gitlab-mcp
  3. Capture the "hash mismatch in fixed-output derivation" message. The
     line that says "got: sha256-..." is the real hash. Update src.hash.
  4. Run nix build again. The next failure reports the real npmDepsHash.
     Update npmDepsHash.
  5. Run nix build a third time. Should succeed.

  Budget: 3 fakeHash rounds maximum (src hash, npmDepsHash, final verify).
  If a 4th round is triggered (unexpected hash), escalate with token
  [hash-mismatch-unexpected] and the full nix build error.

After the overlay file exists, register it in overlays/default.nix:

  Read: /home/caubut/Documents/projects/nix-agentic-tools-ideation/overlays/default.nix

  Insert between the github-mcp block (around line 80-82) and the kagi-mcp
  block (line 83-85). Maintain alphabetical order. Insertion:

    gitlab-mcp = import ./mcp-servers/gitlab-mcp.nix {
      inherit inputs final;
    };

Final step: run treefmt on the two new/modified files.

Return:
  - List of files created/modified
  - The final src.hash and npmDepsHash values
  - Confirmation that `nix build .#ai.mcpServers.gitlab-mcp` exited 0
  - Output of `ls -l result/bin/` (must show gitlab-mcp)

DO NOT:
  - Use nvfetcher (this repo uses inline hashes for source-built packages)
  - Use sourceRoot or postUnpack (upstream is single-package, not a workspace)
  - Use dist/ in installPhase paths (upstream emits build/)
  - Replace passthru wholesale (use (old.passthru or {}) // { ... } if
    extending passthru)
  - Use final.X for any build input — only final.stdenv.hostPlatform.system
    may be read from final

Escalation tokens:
  [hash-mismatch-unexpected]   — more than 3 hash rounds needed
  [build-failure-tsc]          — npm run build (tsc) fails
  [build-failure-other]        — non-tsc build error
  [smoke-test-failure]         — installCheckPhase fails
  [upstream-tree-missing]      — index.ts or package.json not at repo root
```

**Verifier prompt:**

```
Verify Phase 1 of docs/plans/gitlab-mcp-packaging.md. You are read-only.

Checks (run in order; stop at first failure):

1. File overlays/mcp-servers/gitlab-mcp.nix exists.
2. File has rev = "3c8a1f367902ba10a2a01e93c86bd68d7a08996a".
3. File uses `ourPkgs = import inputs.nixpkgs { inherit (final.stdenv.
   hostPlatform) system; };` pattern (cache-hit parity).
4. File does NOT reference final.<anything-other-than-stdenv.hostPlatform.system>.
   Grep for `final\.` in the file; only `final.stdenv.hostPlatform.system`
   matches are allowed.
5. File uses `${bun}/bin/bun` not `${nodejs}/bin/node` in installPhase.
6. File uses build/index.js path, not dist/index.js.
7. File sets meta.license = ourPkgs.lib.licenses.mit and meta.mainProgram =
   "gitlab-mcp".
8. overlays/default.nix has a gitlab-mcp entry alphabetically between
   github-mcp and kagi-mcp.
9. Command `nix build .#ai.mcpServers.gitlab-mcp 2>&1 | tail -20` exits 0.
10. Command `nix eval --raw .#ai.mcpServers.gitlab-mcp.meta.mainProgram`
    prints "gitlab-mcp".
11. Command `ls $(nix build .#ai.mcpServers.gitlab-mcp --no-link --print-out-paths)/bin/`
    lists "gitlab-mcp".

Report pass/fail per criterion with evidence (file:line or command output).
```

**Success criteria:** all 11 verifier checks pass.

**HITL checkpoint:** supervisor posts the two new file contents + verifier
report. HITL approves before Phase 2.

---

### Phase 2 — Server module + package scaffold

**Goal:** typed server module loads through `lib.ai.loadServer "gitlab-mcp"`
without error.

**Files touched:**

- `packages/gitlab-mcp/default.nix` (new — barrel)
- `packages/gitlab-mcp/modules/mcp-server.nix` (new — typed schema)
- `packages/gitlab-mcp/lib/mkGitlab.nix` (new — consumer factory)
- `packages/gitlab-mcp/docs/.gitkeep` (new — directory placeholder)
- `packages/gitlab-mcp/fragments/.gitkeep` (new — directory placeholder)

**Worker prompt:**

```
You are implementing Phase 2 of docs/plans/gitlab-mcp-packaging.md.

Reference files to read first:

  /home/caubut/Documents/projects/nix-agentic-tools-ideation/packages/github-mcp/default.nix
  /home/caubut/Documents/projects/nix-agentic-tools-ideation/packages/github-mcp/modules/mcp-server.nix
  /home/caubut/Documents/projects/nix-agentic-tools-ideation/packages/github-mcp/lib/mkGitHub.nix
  /home/caubut/Documents/projects/nix-agentic-tools-ideation/lib/mcp.nix    (lines 1-100 — credential machinery)

Create the following files.

============================================================================
FILE: packages/gitlab-mcp/default.nix
============================================================================

  {
    docs = ./docs;
    fragments = ./fragments;
    lib.ai.mcpServers.mkGitlab = import ./lib/mkGitlab.nix;
  }

============================================================================
FILE: packages/gitlab-mcp/modules/mcp-server.nix
============================================================================

Use this EXACT structure (copy verbatim, then expand the elided list of
typed options per the spec table in the plan's "Typed feature options (v1)"
section):

  {
    lib,
    mcpLib,
    ...
  }: let
    inherit (lib) mkOption types concatStringsSep optionalAttrs;
    knownTools = [
      # 154 entries — see Appendix A2 in the plan. Sorted alphabetically.
      # The list is the union of read-tools + write-tools from A2.
    ];
    toolType = types.either (types.enum knownTools) types.str;
  in {
    meta = {
      modes = {
        stdio = "gitlab-mcp";
        http = "bridge";
      };
      scope = "remote";
      defaultPort = 19761;
      credentialVars = {
        pat      = { envVar = "GITLAB_PERSONAL_ACCESS_TOKEN"; required = true;  };
        apiUrl   = { envVar = "GITLAB_API_URL";               required = false; };
        jobToken = { envVar = "GITLAB_JOB_TOKEN";             required = false; };
      };
      tools = knownTools;
    };

    settingsOptions = {
      pat      = mcpLib.mkCredentialsOption "GITLAB_PERSONAL_ACCESS_TOKEN";
      apiUrl   = mcpLib.mkCredentialsOption "GITLAB_API_URL";
      jobToken = mcpLib.mkCredentialsOption "GITLAB_JOB_TOKEN";

      instanceUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          GitLab API base URL (e.g. https://gitlab.example.com/api/v4).
          Plain typed config — the value lands in the Nix store. Use
          settings.apiUrl.file/helper instead if the URL must be kept out
          of the store. Mutually exclusive with settings.apiUrl.
        '';
      };

      caCertPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to a custom CA certificate for self-hosted GitLab (GITLAB_CA_CERT_PATH).";
      };

      defaultProjectId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional default GitLab project ID (GITLAB_PROJECT_ID).";
      };

      allowedProjectIds = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Comma-joined allowlist of project IDs (GITLAB_ALLOWED_PROJECT_IDS).";
      };

      readOnly = mkOption {
        type = types.bool;
        default = false;
        description = "Restrict to read-only tools (GITLAB_READ_ONLY_MODE).";
      };

      toolsets = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Toolset IDs to enable (GITLAB_TOOLSETS), comma-joined.";
      };

      tools = mkOption {
        type = types.listOf toolType;
        default = [];
        description = "Individual tool names to enable (GITLAB_TOOLS), comma-joined.";
      };

      deniedToolsRegex = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Regex denylist on tool names (GITLAB_DENIED_TOOLS_REGEX).";
      };

      useWiki = mkOption {
        type = types.bool;
        default = false;
        description = "Legacy: enable wiki tools (USE_GITLAB_WIKI). Prefer toolsets.";
      };

      useMilestone = mkOption {
        type = types.bool;
        default = false;
        description = "Legacy: enable milestone tools (USE_MILESTONE). Prefer toolsets.";
      };

      usePipeline = mkOption {
        type = types.bool;
        default = false;
        description = "Legacy: enable pipeline tools (USE_PIPELINE). Prefer toolsets.";
      };
    };

    settingsToEnv = cfg: _mode: let
      s = cfg.settings;
      instanceUrlSet = s.instanceUrl != null;
      apiUrlCredSet =
        (s.apiUrl.file or null) != null
        || (s.apiUrl.helper or null) != null;
    in
      if instanceUrlSet && apiUrlCredSet
      then
        throw ''
          gitlab-mcp: cannot set both `settings.instanceUrl` (literal URL)
          and `settings.apiUrl` (file/helper credential). Pick one — use
          `instanceUrl` for plain config, or `apiUrl.file` to keep the URL
          out of the Nix store (sops/agenix).''
      else
        optionalAttrs instanceUrlSet                  { GITLAB_API_URL             = s.instanceUrl; }
        // optionalAttrs (s.caCertPath != null)       { GITLAB_CA_CERT_PATH        = s.caCertPath; }
        // optionalAttrs (s.defaultProjectId != null) { GITLAB_PROJECT_ID          = s.defaultProjectId; }
        // optionalAttrs (s.allowedProjectIds != [])  { GITLAB_ALLOWED_PROJECT_IDS = concatStringsSep "," s.allowedProjectIds; }
        // optionalAttrs s.readOnly                   { GITLAB_READ_ONLY_MODE      = "true"; }
        // optionalAttrs (s.toolsets != [])           { GITLAB_TOOLSETS            = concatStringsSep "," s.toolsets; }
        // optionalAttrs (s.tools != [])              { GITLAB_TOOLS               = concatStringsSep "," s.tools; }
        // optionalAttrs (s.deniedToolsRegex != null) { GITLAB_DENIED_TOOLS_REGEX  = s.deniedToolsRegex; }
        // optionalAttrs s.useWiki                    { USE_GITLAB_WIKI            = "true"; }
        // optionalAttrs s.useMilestone               { USE_MILESTONE              = "true"; }
        // optionalAttrs s.usePipeline                { USE_PIPELINE               = "true"; };

    settingsToArgs = _cfg: _mode: [];
  }

NOTES (frozen — do not improvise away from this):

1. credentialVars KEYS == settingsOptions KEYS for the three credentials
   (`pat`, `apiUrl`, `jobToken`). The credential pipeline at
   lib/mcp.nix:104 does `settings.${optName}` where optName is the
   credentialVars key.
2. The `instanceUrl` ↔ `apiUrl` mutex is enforced via `if/throw` at the
   top of settingsToEnv. `evalSettings` in lib/mcp.nix:27-37 discards
   `eval.assertions`, so module-level assertions silently no-op — DO NOT
   try to use them.
3. knownTools is the full 154-entry list from Appendix A2 (read tools +
   write tools, merged and sorted alphabetically). Embed it verbatim
   inside `let knownTools = [ ... ]`.

============================================================================
FILE: packages/gitlab-mcp/lib/mkGitlab.nix
============================================================================

Use the sentinel-comment shape from packages/github-mcp/lib/mkGitHub.nix.
Mirror it verbatim, swapping the names:

  - GitHub → Gitlab (camelCase) and GITLAB (envvar caps)
  - mkGitHub → mkGitlab
  - GITHUB_PERSONAL_ACCESS_TOKEN → GITLAB_PERSONAL_ACCESS_TOKEN
  - github-mcp → gitlab-mcp

============================================================================
FILE: packages/gitlab-mcp/docs/.gitkeep    (empty file)
FILE: packages/gitlab-mcp/fragments/.gitkeep    (empty file)
============================================================================

Final step: treefmt on all new files.

Return:
  - List of files created
  - Output of:
      nix eval --impure --expr '
        let
          lib = (import <nixpkgs> {}).lib;
          mcpLib = import ./lib/mcp.nix { inherit lib; };
          srv = mcpLib.loadServer "gitlab-mcp";
        in builtins.attrNames srv
      '
    (should contain "meta", "settingsOptions", "settingsToArgs", "settingsToEnv")
  - Output of:
      nix eval --impure --expr '
        let
          lib = (import <nixpkgs> {}).lib;
          mcpLib = import ./lib/mcp.nix { inherit lib; };
          evald = mcpLib.evalSettings "gitlab-mcp" {};
        in evald.readOnly
      '
    (should print "false" — confirms defaults work)

Escalation tokens:
  [server-module-eval-failure]  — loadServer throws
  [settings-evaluation-failure] — evalSettings throws on default config
  [knowntools-eval-failure]     — eval fails when meta.tools is referenced
                                  (likely large enum overhead — escalate)
```

**Verifier prompt:**

```
Verify Phase 2 of docs/plans/gitlab-mcp-packaging.md. Read-only.

Checks:

1. Files exist:
   - packages/gitlab-mcp/default.nix
   - packages/gitlab-mcp/modules/mcp-server.nix
   - packages/gitlab-mcp/lib/mkGitlab.nix
   - packages/gitlab-mcp/docs/.gitkeep
   - packages/gitlab-mcp/fragments/.gitkeep

2. packages/gitlab-mcp/default.nix barrel contains:
   - docs = ./docs;
   - fragments = ./fragments;
   - lib.ai.mcpServers.mkGitlab = import ./lib/mkGitlab.nix;

3. mcp-server.nix declares:
   - meta.modes.stdio = "gitlab-mcp"
   - meta.modes.http = "bridge"
   - meta.scope = "remote"
   - meta.defaultPort = 19761
   - meta.credentialVars with three flat keys: pat, apiUrl, jobToken
   - meta.tools (a list with ≥150 entries)
   - settingsOptions has matching flat keys pat / apiUrl / jobToken
     (all `mcpLib.mkCredentialsOption`), plus instanceUrl / caCertPath /
     defaultProjectId / allowedProjectIds / readOnly / toolsets / tools /
     deniedToolsRegex / useWiki / useMilestone / usePipeline.
   - settingsToEnv contains an `if instanceUrlSet && apiUrlCredSet then
     throw` guard at the top.
   - settingsToArgs returns [] for stdio mode.

4. The credentialVars keys exactly match three settingsOptions keys:
   pat, apiUrl, jobToken. Grep both blocks and confirm.

5. Eval test:
     nix eval --impure --expr '
       let
         lib = (import <nixpkgs> {}).lib;
         mcpLib = import ./lib/mcp.nix { inherit lib; };
         srv = mcpLib.loadServer "gitlab-mcp";
       in builtins.attrNames srv
     '
   Must exit 0 and contain "meta", "settingsOptions", "settingsToArgs",
   "settingsToEnv".

6. Default-settings eval test:
     nix eval --impure --expr '
       let
         lib = (import <nixpkgs> {}).lib;
         mcpLib = import ./lib/mcp.nix { inherit lib; };
         evald = mcpLib.evalSettings "gitlab-mcp" {};
       in evald.readOnly
     '
   Must exit 0 and print "false".

7. Conflict assertion fires:
     nix eval --impure --expr '
       let
         lib = (import <nixpkgs> {}).lib;
         mcpLib = import ./lib/mcp.nix { inherit lib; };
         srv = mcpLib.loadServer "gitlab-mcp";
         conflictingCfg = {
           instanceUrl = "https://example.com";
           apiUrl.file = "/run/secrets/url";
         };
         cfgShim = { settings = mcpLib.evalSettings "gitlab-mcp" conflictingCfg;
                     service = { port = null; host = "127.0.0.1"; }; };
       in builtins.tryEval (srv.settingsToEnv cfgShim "stdio")
     '
   The tryEval result should be { success = false; value = false; } — the
   throw should fire, which tryEval traps as success=false.

Report pass/fail per criterion with evidence.
```

**Success criteria:** all 7 verifier checks pass.

**HITL checkpoint:** supervisor posts the three new content files + verifier
report + the credentials-nesting decision the worker took.

---

### Phase 3 — Registrations across the monorepo

**Goal:** every registration touchpoint contains a gitlab-mcp entry; nothing
manual remains.

**Files touched (10 files, 11 insertions):**

1. `packages/default.nix` — barrel import
2. `config/update-matrix.nix` — update config block
3. `README.md` — feature matrix row + count
4. `config/cspell/project-terms.txt` — new terms
5. `dev/data.nix` — metadata description
6. `packages/mcp-services/modules/homeManager/default.nix` — server names list
7. `checks/cache-hit-parity.nix` — package list
8. `checks/factory-eval.nix` — two tests (loadServer + module existence)
9. `checks/module-eval.nix` — server-option-tree assertion

(overlays/default.nix was handled in Phase 1.)

**Worker prompt:**

```
You are implementing Phase 3 of docs/plans/gitlab-mcp-packaging.md.
Mechanical registration insertions — no design judgment required. Every
insertion is precisely specified below. Do not invent additional changes.

1. File: packages/default.nix
   - Insert alphabetically between github-mcp and kagi-mcp lines:
       gitlab-mcp = import ./gitlab-mcp;

2. File: config/update-matrix.nix
   - Insert alphabetically between github-mcp block and kagi-mcp block:
       gitlab-mcp = {
         flags = "--version skip";
         git = "https://github.com/zereight/gitlab-mcp.git";
       };

3. File: README.md
   - The MCP feature matrix is ALSO generated from dev/data.nix (see step
     5) via dev/generate.nix:373-377. The `repo-readme` derivation that
     would copy generated content into README.md is not currently wired
     into flake.nix — until it is, README.md is hand-maintained AND
     dev/data.nix is the future source of truth. Edit both.
   - Locate the MCP feature matrix section heading "MCP Servers".
   - Update the server count from "(N servers)" to "(N+1 servers)" — grep
     for the current count and increment by 1; the heading is around line
     128.
   - Insert a new row alphabetically between github-mcp and kagi-mcp:
       | `gitlab-mcp` | GitLab platform integration | Required |

4. File: config/cspell/project-terms.txt
   - This file is sorted alphabetically. Insert at the correct positions:
       gitlab
       glpat
       mcpgitlab
       zereight
   - Only add a term if it doesn't already exist (gitlab and zereight may
     appear elsewhere; check before insertion).

5. File: dev/data.nix
   - In the mcpServerMeta attrset, insert alphabetically between github-mcp
     and kagi-mcp blocks:
       gitlab-mcp = {
         description = "GitLab platform integration";
         credentials = "Required";
       };

6. File: packages/mcp-services/modules/homeManager/default.nix
   - In the server names list, insert "gitlab-mcp" alphabetically between
     "github-mcp" and "kagi-mcp".

7. File: checks/cache-hit-parity.nix
   - In the mcpServerPackages list, insert "gitlab-mcp" alphabetically
     between "github-mcp" and "kagi-mcp".
   - If a comment elsewhere in the file states a server count, update it.

8. File: checks/factory-eval.nix
   - Add ONE test (the existing factory pattern only has a single
     `factory-loadServer-<pkg>-from-package-dir` per package; the
     "package-module-exists" assertion is folded into the same file but is
     not a separate test entry for kagi-mcp or context7-mcp — match
     whatever surrounds github-mcp's tests). Insert between the github-mcp
     test and the kagi-mcp test:

     factory-loadServer-gitlab-mcp-from-package-dir = mkTest "loadServer-gitlab-mcp-from-package-dir" (
       let
         mcpLib = import ../lib/mcp.nix {inherit lib;};
         serverDef = mcpLib.loadServer "gitlab-mcp";
       in
         serverDef ? settingsOptions
         && serverDef.settingsOptions ? pat
     );

   Phase 2 used flat key `pat` for the GITLAB_PERSONAL_ACCESS_TOKEN
   credential — that's what `settingsOptions ? pat` checks. If you find
   github-mcp's tests use a different assertion shape (e.g. checking for
   a different option name), match that shape but keep `pat` as the
   gitlab-mcp credential probe.

9. File: checks/module-eval.nix
   - Grep for the test `module-mcp-services-option-tree` (around line
     1203). It contains a conjunction of `servers ? <name>` lines:

       servers ? context7-mcp
       && servers ? effect-mcp
       && servers ? fetch-mcp
       && servers ? git-intel-mcp
       && servers ? git-mcp
       && servers ? github-mcp
       && servers ? kagi-mcp
       ...

   - Insert a new line alphabetically between `&& servers ? github-mcp`
     and `&& servers ? kagi-mcp`:

       && servers ? gitlab-mcp

   - Do NOT use line numbers — grep for the test name and edit relative
     to that anchor.

After all insertions, run treefmt on every file touched.

Return:
  - List of files modified with line ranges
  - Output of `git diff --stat`
  - Confirmation that each insertion is alphabetically sorted

Escalation tokens:
  [insertion-point-not-found]  — the surrounding github-mcp / kagi-mcp lines
                                 don't match the plan's description
  [duplicate-entry-detected]   — an entry already exists from prior work
  [unexpected-file-structure]  — file shape diverges from plan's description
```

**Verifier prompt:**

```
Verify Phase 3 of docs/plans/gitlab-mcp-packaging.md. Read-only.

Run for each of the 9 files in the plan's Phase 3 list:
  - grep -n "gitlab-mcp" <file>   (or "gitlab" for cspell)
  - Confirm the new line(s) are alphabetically positioned between the
    github-mcp and kagi-mcp neighbors (or, where the file has different
    ordering, between the lexically nearest neighbors).

Then run:
  nix flake check 2>&1 | tail -40
  echo "Exit: $?"

The flake check must exit 0. If it fails, report the failure category:
  - module-eval error
  - factory-eval error
  - cache-hit-parity drift
  - formatting / treefmt
  - other (paste the relevant tail)

Verify treefmt is clean:
  treefmt --fail-on-change
  echo "Exit: $?"

Report pass/fail per criterion with evidence.
```

**Success criteria:** all 9 file insertions present + `nix flake check`
exits 0 + treefmt clean.

**HITL checkpoint:** supervisor posts `git diff --stat` + verifier report.

---

### Phase 4 — Documentation + tool taxonomy

**Goal:** `packages/gitlab-mcp/docs/README.md` exists with the read/write
tool split so consumers can build `trustedMcpTools` lists.

**Files touched:**

- `packages/gitlab-mcp/docs/README.md` (new — replaces the .gitkeep)
- `packages/gitlab-mcp/docs/.gitkeep` (deleted)

**Worker prompt:**

```
You are implementing Phase 4 of docs/plans/gitlab-mcp-packaging.md.

Create packages/gitlab-mcp/docs/README.md with this structure:

  # gitlab-mcp

  MCP server for GitLab platform integration. Wraps zereight/gitlab-mcp
  (npm @zereight/mcp-gitlab) as a Nix-built stdio MCP server with typed
  settings for credentials, GitLab API targeting, and tool selection.

  ## Configuration

  ### Authentication

  Requires a GitLab Personal Access Token (PAT) with appropriate scopes.

  Via sops-nix:

      ai.mcpServers.gitlab-mcp = {
        enable = true;
        settings.pat.file = config.sops.secrets."gitlab-mcp/token".path;
      };

  Optional CI job token (alternate auth path):

      settings.jobToken.file = config.sops.secrets."gitlab-mcp/job-token".path;

  ### Self-hosted GitLab

  Two ways to point at a non-default instance — mutually exclusive:

  1. Plain string (URL lands in the Nix store):

         ai.mcpServers.gitlab-mcp.settings.instanceUrl =
           "https://gitlab.example.com/api/v4";

  2. From a secret file (URL stays encrypted at rest):

         ai.mcpServers.gitlab-mcp.settings.apiUrl.file =
           config.sops.secrets."gitlab-mcp/api-url".path;

  Setting both fails eval — pick one.

  ## Trust posture

  Consumers configuring `trustedMcpTools` can copy these lists verbatim.

  Read-only tools (safe to auto-trust): 84 tools, list below.
  Write tools (require per-call approval): 70 tools, list below.

  Note: `execute_graphql` is listed under reads but is dual-use (depends
  on the GraphQL query). Strict policies should classify it as write.

  ### Read tools (84)

  [paste from plan Appendix A2-read]

  ### Write tools (70)

  [paste from plan Appendix A2-write]

  ## Tool selection at runtime

  The upstream server supports trimming the exposed tool surface via:

  - `settings.toolsets`  — comma-joined GITLAB_TOOLSETS
  - `settings.tools`     — comma-joined GITLAB_TOOLS (additive)
  - `settings.deniedToolsRegex` — GITLAB_DENIED_TOOLS_REGEX
  - `settings.readOnly`  — GITLAB_READ_ONLY_MODE (excludes all write tools)

  ## Out-of-v1 scope

  OAuth-based authentication (GITLAB_USE_OAUTH, GITLAB_MCP_OAUTH, stateless
  mode, callback proxy) is not yet exposed as typed options. Use the
  freeform `env = { … }` escape hatch on `mkStdioEntry` if needed.

Delete packages/gitlab-mcp/docs/.gitkeep.

Run treefmt on the new README.

Return:
  - File path created
  - Confirmation that the read+write counts (84+70) sum to 154
  - Whether you embedded the full tool lists (yes/no)
```

**Verifier prompt:**

```
Verify Phase 4 of docs/plans/gitlab-mcp-packaging.md. Read-only.

Checks:

1. packages/gitlab-mcp/docs/README.md exists.
2. packages/gitlab-mcp/docs/.gitkeep does NOT exist.
3. The README contains both "### Read tools" and "### Write tools" sections.
4. The combined unique tool names across both sections equals 154
   (use awk/grep to extract tool names — they are lowercase_with_underscores).
5. treefmt --fail-on-change exits 0.

Report pass/fail per criterion with evidence.
```

**Success criteria:** all 5 verifier checks pass.

**HITL checkpoint:** supervisor posts the new README + verifier report.

---

### Phase 5 — Final verification + commit

**Goal:** the full validation entrypoint passes; work is committed as small
linear commits.

**Files touched:** none (validation + git only).

**Worker prompt:**

```
You are implementing Phase 5 of docs/plans/gitlab-mcp-packaging.md.

Run, in order. Stop and escalate on any failure:

1. nix flake check 2>&1 | tail -40 ; echo "Exit: $?"
2. nix build .#ai.mcpServers.gitlab-mcp --no-link --print-out-paths
3. treefmt --fail-on-change ; echo "Exit: $?"
4. pre-commit run --all-files 2>&1 | tail -40 ; echo "Exit: $?"
   (If pre-commit is not wired, skip this step.)

If all pass, stage and commit in this order. Small linear commits per the
user's preference — intermediate commits are NOT required to pass full
`nix flake check`; the user will restack later. Only the FINAL state
(after all four commits) must pass validation. The validation in steps
1-4 above was run against that final state.

  Commit 1 (overlay):
    git add overlays/mcp-servers/gitlab-mcp.nix overlays/default.nix
    git commit -m "feat(overlay): add gitlab-mcp package"

  Commit 2 (server module + factory):
    git add packages/gitlab-mcp/default.nix \
            packages/gitlab-mcp/modules/ \
            packages/gitlab-mcp/lib/ \
            packages/gitlab-mcp/fragments/ \
            packages/gitlab-mcp/docs/.gitkeep
    git commit -m "feat(gitlab-mcp): typed server module and factory"

  Commit 3 (registrations):
    git add packages/default.nix config/update-matrix.nix README.md \
            config/cspell/project-terms.txt dev/data.nix \
            packages/mcp-services/modules/homeManager/default.nix \
            checks/cache-hit-parity.nix checks/factory-eval.nix \
            checks/module-eval.nix
    git commit -m "feat(gitlab-mcp): register across monorepo"

  Commit 4 (docs):
    git add packages/gitlab-mcp/docs/README.md
    git rm packages/gitlab-mcp/docs/.gitkeep    # if it was tracked in commit 2
    git commit -m "docs(gitlab-mcp): tool taxonomy and consumer config"

Use --author from `git config` defaults. Co-Authored-By footer per the
repo's convention if other commits in `git log -5` show it. Use HEREDOC
for the message body if multi-line.

Do NOT push. Do NOT amend. Leave the commits on the current branch.

Return:
  - Output of `git log --oneline -5`
  - Output of `git status`
  - Confirmation that no untracked files remain in packages/gitlab-mcp/
    or overlays/mcp-servers/

Escalation tokens:
  [validation-flake-check]   — nix flake check fails after all phases
  [validation-build]         — nix build .#ai.mcpServers.gitlab-mcp fails
  [validation-treefmt]       — treefmt --fail-on-change reports diffs
  [validation-pre-commit]    — pre-commit hook fails
  [commit-rejection]         — pre-commit hook blocks the commit
```

**Verifier prompt:**

```
Verify Phase 5 of docs/plans/gitlab-mcp-packaging.md. Read-only.

Checks:

1. `nix flake check 2>&1 | tail -20 ; echo "Exit: $?"` exits 0.
2. `git status --porcelain` returns empty (no untracked files, no diffs).
3. `git log --oneline -5` shows the four feat(...)/docs(...) commits in
   the order specified, all attributable to the configured git user.
4. `nix build .#ai.mcpServers.gitlab-mcp --no-link --print-out-paths`
   exits 0 and prints a store path.
5. The store path's bin directory contains `gitlab-mcp` executable.

Report pass/fail per criterion with evidence.
```

**Success criteria:** all 5 verifier checks pass.

**HITL checkpoint:** supervisor posts `git log -5` + verifier report.
HITL decides whether to push.

---

## Failure-mode taxonomy

Workers report failures with classification tokens. Supervisor responds:

| Token                           | Supervisor action                                                                                                                                  |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[hash-mismatch-unexpected]`    | Surface to HITL. Likely cause: wrong rev, wrong upstream URL, or upstream re-tagged.                                                               |
| `[build-failure-tsc]`           | Surface to HITL with the tsc error tail. Likely cause: upstream changed tsconfig or build script between when this plan was written and execution. |
| `[build-failure-other]`         | Surface to HITL with the build log tail.                                                                                                           |
| `[smoke-test-failure]`          | Surface to HITL with the smoke test output. Likely cause: bun cannot execute the ESM entry. Possible pivot: use `${nodejs}/bin/node` wrapper.      |
| `[upstream-tree-missing]`       | Surface to HITL. Likely cause: rev SHA wrong.                                                                                                      |
| `[server-module-eval-failure]`  | Surface to HITL with full eval trace.                                                                                                              |
| `[settings-evaluation-failure]` | Surface to HITL with the option-eval error.                                                                                                        |
| `[knowntools-eval-failure]`     | Surface to HITL. 154-entry `types.enum` may have hit a limit. Pivot: drop the enum and use `types.listOf types.str` for the `tools` option.        |
| `[insertion-point-not-found]`   | Surface to HITL. Likely cause: file has been reordered since the plan was written. Re-derive the insertion point and dispatch again.               |
| `[duplicate-entry-detected]`    | Surface to HITL. Confirms idempotency violation — investigate.                                                                                     |
| `[unexpected-file-structure]`   | Surface to HITL with the file content.                                                                                                             |
| `[validation-flake-check]`      | Surface to HITL with the failing check name.                                                                                                       |
| `[validation-build]`            | Surface to HITL with the build error.                                                                                                              |
| `[validation-treefmt]`          | Worker should re-run `treefmt` and commit. If still fails, escalate.                                                                               |
| `[validation-pre-commit]`       | Surface to HITL with the failing hook name.                                                                                                        |
| `[commit-rejection]`            | Surface to HITL. Do NOT --no-verify. Fix and recommit.                                                                                             |

Any error not in this table is also surfaced to HITL — workers do not
improvise.

---

## Appendix A1 — Reserved (server-module template)

The Phase 2 worker prompt embeds the necessary template structure inline.
Use packages/github-mcp/modules/mcp-server.nix as the reference shape for
the surrounding lib bindings (mkOption / types / etc.).

## Appendix A2 — Tool lists

### Read tools (84)

```
download_attachment
download_job_artifacts
download_release_asset
execute_graphql
get_branch_diffs
get_commit
get_commit_diff
get_deployment
get_draft_note
get_environment
get_file_contents
get_group_wiki_page
get_issue
get_issue_link
get_job_artifact_file
get_label
get_merge_request
get_merge_request_approval_state
get_merge_request_conflicts
get_merge_request_diffs
get_merge_request_file_diff
get_merge_request_note
get_merge_request_notes
get_merge_request_version
get_milestone
get_milestone_burndown_events
get_milestone_issue
get_milestone_merge_requests
get_namespace
get_pipeline
get_pipeline_job
get_pipeline_job_output
get_project
get_project_events
get_release
get_repository_tree
get_tag
get_tag_signature
get_timeline_events
get_users
get_webhook_event
get_wiki_page
get_work_item
list_commit_statuses
list_commits
list_custom_field_definitions
list_deployments
list_draft_notes
list_environments
list_events
list_group_iterations
list_group_projects
list_group_wiki_pages
list_issue_discussions
list_issue_links
list_issues
list_job_artifacts
list_labels
list_merge_request_changed_files
list_merge_request_diffs
list_merge_request_pipelines
list_merge_request_versions
list_merge_requests
list_milestones
list_namespaces
list_pipeline_jobs
list_pipeline_trigger_jobs
list_pipelines
list_project_members
list_projects
list_releases
list_tags
list_todos
list_webhook_events
list_webhooks
list_wiki_pages
list_work_item_notes
list_work_item_statuses
list_work_items
mr_discussions
my_issues
search_code
search_group_code
search_project_code
search_repositories
validate_ci_lint
validate_project_ci_lint
verify_namespace
```

### Write tools (70)

```
approve_merge_request
bulk_publish_draft_notes
cancel_pipeline
cancel_pipeline_job
convert_work_item_type
create_branch
create_commit_status
create_draft_note
create_group_wiki_page
create_issue
create_issue_link
create_issue_note
create_label
create_merge_request
create_merge_request_discussion_note
create_merge_request_note
create_merge_request_thread
create_milestone
create_note
create_or_update_file
create_pipeline
create_release
create_release_evidence
create_repository
create_tag
create_timeline_event
create_wiki_page
create_work_item
create_work_item_note
delete_draft_note
delete_group_wiki_page
delete_issue
delete_issue_link
delete_label
delete_merge_request_discussion_note
delete_merge_request_note
delete_milestone
delete_release
delete_tag
delete_wiki_page
edit_milestone
fork_repository
mark_all_todos_done
mark_todo_done
merge_merge_request
move_work_item
play_pipeline_job
promote_milestone
publish_draft_note
push_files
resolve_merge_request_thread
retry_pipeline
retry_pipeline_job
unapprove_merge_request
update_draft_note
update_group_wiki_page
update_issue
update_issue_note
update_label
update_merge_request
update_merge_request_discussion_note
update_merge_request_note
update_milestone
update_release
update_wiki_page
update_work_item
upload_markdown
```

The full `knownTools` list embedded in `meta.tools` is the union of the
two above, sorted alphabetically — 154 entries.

## Appendix A3 — Inline guardrails (mistakes the prior LLM handoff would have caused)

Embedded in the relevant phases above as `DO NOT` lists. Three guardrails
worth restating in one place because the original handoff prompt would have
led a fresh implementer astray on each:

1. **Don't introduce nvfetcher** — this repo uses inline `rev` + `hash` for
   source-built packages and per-platform JSON sidecars for binary-only
   packages. `nix-update` handles bumps. Phase 1's hash-bootstrap procedure
   is the standard mechanism.
2. **Don't set `meta.external = true`** — that flag is for MCP servers that
   _are themselves_ hosted as remote HTTP services. Self-hosted GitLab is
   a runtime configuration on a locally-running stdio server; `instanceUrl`
   handles it.
3. **Don't extend `mkCredentialsOption` with a literal-value tag** — the
   per-credential file/helper schema must stay closed so PATs can't be
   accidentally placed in the Nix store. The `instanceUrl` plain-string
   option is declared separately at the module level, opt-in per field.

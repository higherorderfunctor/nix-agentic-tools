## Copilot config delivery — two consumers, one product name

> **Last verified:** 2026-09-22 — normalized reasoning effort lowers to the
> persisted `effortLevel` key at both user and repository scope. The
> unscoped-frontmatter measurement (1.0.79) is retained as the durable record
> after the normalized-interface plan was retired; it was not re-measured at
> 1.0.80.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 89dce4c4:dev/fragments/ai-clis/copilot-config-delivery.md`.
>
> - **The wrapper lives in one place, not duplicated per backend.** Both
>   backends now share `packages/copilot-cli/lib/wrapPackage.nix`, exercised by
>   `packages/copilot-cli/checks/copilot-wrapper-argv.nix`. Inlining it once per
>   backend is what let the identical pair of defects — builder-expanded
>   `$HOME`, missing `@` prefix — ship twice, as #767 and then #769.

### The trap: "Copilot" is two different consumers here

This repo uses Copilot in two distinct ways. Their instruction surfaces are
separate, while the local CLI also reads a documented subset of repository
settings. Conflating the consumers is the default mistake — it is why the two
config directories look redundant when they are not.

| consumer                                | reads                                                                                      | committed?        |
| --------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------- |
| **copilot-cli** (local agent harness)   | `$HOME/.copilot/*`, `.github/copilot/settings.json`, plus `--additional-mcp-config`        | mixed             |
| **github.com Copilot code review** (CI) | `projectDir` = `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` | **yes, required** |

So: do not "consolidate" the two directories, and do not move reviewer content
out of `.github/`.

### `configDir` names two different directories, one per backend

This is the second trap, and it sits underneath the first.
`ai.copilot.configDir` is one option NAME with two defaults. Home Manager uses
it as the CLI's user root; devenv uses it only for wrapper-injected files:

| backend      | default                                  | is it the CLI's home?                         |
| ------------ | ---------------------------------------- | --------------------------------------------- |
| Home Manager | `.copilot` (HOME-relative)               | **yes** — `COPILOT_HOME`'s canonical location |
| devenv       | `.config/github-copilot` (root-relative) | no — wrapper-aimed only                       |

An earlier revision of this fragment said flatly that "`configDir`
(`.config/github-copilot/`) belongs to NEITHER by discovery … the CLI does not
look there." That is correct about the devenv default and **false about the HM
one**, where `configDir` is precisely where the CLI looks. The devenv default is
gitignored, so the server-side reviewer cannot see it even in principle, and it
exists solely as a target for CLI wrapper flags. Live repository settings use
neither `configDir` nor configurable `projectDir`; Copilot discovers the fixed
`.github/copilot/settings.json` path.

Read a `configDir` cite with the backend attached, or the two collapse into a
statement that is wrong half the time.

### Home Manager normalized context and rules intentionally do not emit

The normalized context/rules model targets repository guidance consumed by
github.com's Copilot reviewer. Devenv writes
`<projectDir>/copilot-instructions.md` and
`<projectDir>/instructions/<key>.instructions.md`; matcher globs become the
comma-joined `applyTo` field and descriptions are forwarded. Home Manager keeps
the same typed options to preserve exact backend schema parity, but emits
nothing for either pool because copilot-cli user-global content is a separate
product surface. This is an intentional capability-reducing degradation.

### Historical Home Manager named instructions and rules path

`mkCopilot.nix` hardcoded `.github/instructions/<name>.instructions.md` on BOTH
backends. On devenv that is right — it is the committed reviewer surface. On
Home Manager the same literal resolves to `$HOME/.github/instructions/`, which
is not a Copilot surface at all: `.github` is a repository convention, and there
is no user-global reading of it. So every named legacy instruction and every
rule emitted a file under HM and nothing ever loaded it.

An intermediate fix prefixed `cfg.configDir`, proving that copilot-cli can read
that user-global directory. The normalized redesign then removed Home Manager
context/rule emission entirely: these options describe repository guidance for
github.com's reviewer, while CLI-global content is a different product surface.
The devenv `.github` arm remains the live destination.

**The destination is live — measured, not assumed** (2026-08-14, 1.0.80). This
is the one thing worth checking before trusting the fix, since the defect being
fixed was precisely a write to a path nobody reads. Two independent lines of
evidence, both with passing positive controls:

- **End-to-end**: with `COPILOT_OFFLINE=true` and `COPILOT_PROVIDER_BASE_URL`
  pointed at a local capture server, a marker placed in
  `$HOME/.copilot/instructions/probe.instructions.md` appears verbatim in the
  outgoing system prompt. `strace` shows the matching `openat(O_DIRECTORY)` +
  `getdents64` + read. Negative control: `--no-custom-instructions` zeroes every
  marker while the request is still captured.
- **Static**: the binary's own enumeration lists
  `$HOME/.copilot/instructions/**/*.instructions.md`.

Two properties the emission depends on, both measured: the walk is **recursive**
(`**` is real), and it is **suffix-gated** — a `plain.md` dropped in that
directory is ignored, so the `<name>.instructions.md` filename this module emits
is load-bearing rather than cosmetic.

The full 1.0.80 list, from the binary's own `/help` text and consistent with
what was measured:

```
CLAUDE.md                                    (git root & cwd)
GEMINI.md                                    (git root & cwd)
AGENTS.md                                    (git root & cwd)
.github/instructions/**/*.instructions.md    (git root & cwd)
.github/copilot-instructions.md              (git root & cwd)
$HOME/.copilot/copilot-instructions.md
$HOME/.copilot/instructions/**/*.instructions.md
COPILOT_CUSTOM_INSTRUCTIONS_DIRS             (extra dirs, comma-separated)
```

One detail that matters if anyone ever tunes the transformer, and it is worth
stating with its measurement status attached because an earlier draft of this
paragraph got it backwards:

- **`applyTo:` IS consumed as routing metadata — MEASURED.** The Rust core
  (`runtime.node`) parses it as a glob and carries the diagnostic
  `(ignoring malformed applyTo glob pattern`. An earlier revision of this
  fragment claimed the header was passed to the model as inert text; that half
  is refuted. Note the trap that produced it: grepping the JS bundle for
  `applyTo` returns only `applyToken` / `applyToolDeferralPlan` substring hits,
  so a careless positive control "passes" while proving nothing about the key.
  Match it as a word.
- **Frontmatter ALSO reaches the prompt for unscoped files** — measured at
  1.0.79 during the normalized-rules redesign, and NOT re-measured at 1.0.80
  here. Every universal-`applyTo` file is concatenated into one run with no
  delimiter between files and with its raw YAML inlined as prose, while a SCOPED
  file keeps per-file identity through a `| Pattern | File Path | Description |`
  index row.

The two are consistent — routing is parsed, and the unscoped bucket is inlined
anyway — but do not restate either half without the other, and do not restate
the second as though this fragment measured it.

**What the frontmatter-inlining does NOT license.** Do not route always-on rule
content through the context file. `ai.context` is a single baseline, not a pool,
and pushing rule content there discards keyed identity. On devenv the convention
is named files; the transformer emits `applyTo: "**"` when `matcher == null`,
which puts always-on rules in Copilot's injected tier.

### Measured discovery (copilot-cli 1.0.78)

Syscall trace, project cwd, all four devenv-written files present:

```bash
strace -f -qq -e trace=openat,newfstatat copilot -p "hi" 2>&1 \
  | grep -oE '"[^"]*/proj/[^"]*"'
```

Inside the project it touches ONLY:

```
./.git
./.github/allowed_models.txt
./.github/copilot-instructions.md
```

`<project>/.config/github-copilot/{mcp-config,lsp-config,settings}.json` are
never opened, and never even stat'd. From `$HOME` it opens
`~/.copilot/{config,mcp-config,lsp-config}.json` plus session state.

### Why not `COPILOT_HOME`

`COPILOT_HOME` **does** work — verified: setting it moves `mcp-config.json`
lookup to `$COPILOT_HOME/mcp-config.json` and stops the `$HOME/.copilot/` read.
(`XDG_CONFIG_HOME` does not; it is ignored for this.)

It is still the wrong tool, because it relocates the ENTIRE copilot home, not
just declarative config. Measured contents after a run with it set:

```
$COPILOT_HOME/config.json          # auth / account state
$COPILOT_HOME/session-store.db     # + -wal, -shm
$COPILOT_HOME/session-state/…      # full conversation history
$COPILOT_HOME/logs/…
```

Pointing that at a project directory would fork authentication per project and
write conversation history into the repo. That is the same failure this repo
already refused for Codex, where devenv materializes files INTO `CODEX_HOME`
rather than re-pointing it, precisely to avoid "forking authentication/session
state".

Copilot needs no such materialize dance, because it has something Codex lacks:
an ADDITIVE flag.

### The chosen mechanism

`--additional-mcp-config` is documented as augmenting, not replacing:

```
--additional-mcp-config <json>   JSON string or file path (prefix with @)
                                 … augments config from ~/.copilot/mcp-config.json
```

So the devenv module wraps `cfg.package` and passes
`@$DEVENV_ROOT/<configDir>/mcp-config.json`. User-global auth and sessions stay
where they are; only servers are added. Two escaping details, both of which have
already shipped as bugs on the HM side:

- `\''${DEVENV_ROOT}` is escaped so the launched shell expands it. Unescaped,
  the BUILDER expands it — that is how
  `/homeless-shelter/.copilot/mcp-config.json` shipped in the HM wrapper.
- `@` marks the value a FILE PATH. Without it the CLI parses the path string as
  JSON and every session dies at startup.

The wrapper is built when there is EITHER an MCP config to point at or an
environment variable to bake — `mergedServers != {}` was the only trigger until
2026-08-10, when `environmentVariables` moved off devenv's project-shell `env`
attrset and onto the wrapper on both backends. On devenv the env arm is
effectively always live, because the default-on `gitSshConfigWorkaround`
contributes `GIT_SSH_COMMAND` there (devenv has no `programs.git`), so an
MCP-less devenv project no longer keeps the bare package. Home Manager still
does, since it states that default in Git's own config instead.

### Why `lsp-config.json` is written but not delivered

There is no `--additional-lsp-config`; the flag surface has exactly one config
injector. So that file cannot be delivered at project scope.

It is still written, and this is deliberate on three counts:

1. Option-surface parity with the HM module, which the config-parity rule wants.
2. Zero cost — gitignored, and it becomes live for free if upstream ever grows
   project-scope discovery.
3. Removing them buys nothing a user can observe.

Settings are no longer part of this limitation. Current Copilot reads
`.github/copilot/settings.json` as repository configuration, and `effortLevel`
is explicitly supported there. The devenv backend writes native settings to the
fixed `.github/copilot/settings.json` path and rejects keys outside Copilot's
documented repository-settings allowlist instead of silently writing ignored
values. Home Manager retains the unrestricted global user-file activation merge.
The normalized `ai.copilot.settings.reasoningEffort` field lowers to
`effortLevel` at `mkDefault` priority in both.

**The inert LSP file is NOT an assertion**, and that is the load-bearing part.
`ai.lspServers` is a SHARED pool that fans out to Claude, Copilot and Kiro.
Asserting on a non-empty pool would hard-fail a devenv project that legitimately
configures LSP servers for Claude and merely happens to enable Copilot too. The
exclusion is therefore documented (option description + this fragment), matching
how Codex's missing LSP surface is handled — excluded and documented, not
asserted.

### What would change this decision

- Upstream adds project-scope LSP discovery, or a second injection flag → drop
  the inert-file caveat and deliver it properly.
- Upstream splits auth/session out of `COPILOT_HOME` → the env-var route becomes
  viable and would remove the wrapper.
- Copilot stops accepting `@`-prefixed paths → the whole delivery mechanism
  changes; the module-eval test asserting the emitted flag will catch it.

## Copilot config delivery — two consumers, one product name

> **Last verified:** 2026-08-05 (commit pending — the wrapper both backends use
> now lives in ONE place, `packages/copilot-cli/lib/wrapPackage.nix`, and is
> exercised behaviorally by `checks/copilot-wrapper-argv.nix`. It had been
> inlined once per backend, and that duplication is why the identical pair of
> defects — builder-expanded `$HOME`, missing `@` prefix — shipped twice, as
> #767 and then #769. Nothing about the DISCOVERY behavior below changed).
> Prior: 2026-08-05 (first version. Records the syscall-traced config discovery
> of copilot-cli 1.0.78, why the devenv MCP fix is a wrapper flag rather than
> `COPILOT_HOME`, and why `lsp-config.json` / `settings.json` stay
> written-but-undelivered instead of asserting). If you change how
> `packages/copilot-cli/` delivers config in either backend, or bump copilot-cli
> across a release that moves config discovery, re-run the probe below and
> update this in the same commit.

### The trap: "Copilot" is two different consumers here

This repo uses Copilot in two unrelated ways, and their config surfaces are
disjoint. Conflating them is the default mistake — it is why the two config
directories look redundant when they are not.

| consumer                                | reads                                                                                      | committed?        |
| --------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------- |
| **copilot-cli** (local agent harness)   | `$HOME/.copilot/*`, plus `--additional-mcp-config`                                         | no — `$HOME`      |
| **github.com Copilot code review** (CI) | `projectDir` = `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` | **yes, required** |

`configDir` (`.config/github-copilot/`) belongs to NEITHER by discovery. It is
gitignored, so the server-side reviewer cannot see it even in principle, and the
CLI does not look there. It exists solely as a target for CLI wrapper flags.

So: do not "consolidate" the two directories, and do not move reviewer content
out of `.github/`.

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

### Why `lsp-config.json` and `settings.json` are written but not delivered

There is no `--additional-lsp-config` and no settings equivalent — the flag
surface has exactly one config injector. So those two files cannot be delivered
at project scope at all.

They are still written, and this is deliberate on three counts:

1. Option-surface parity with the HM module, which the config-parity rule wants.
2. Zero cost — gitignored, and they become live for free if upstream ever grows
   project-scope discovery.
3. Removing them buys nothing a user can observe.

**They are NOT an assertion**, and that is the load-bearing part.
`ai.lspServers` is a SHARED pool that fans out to Claude, Copilot and Kiro.
Asserting on a non-empty pool would hard-fail a devenv project that legitimately
configures LSP servers for Claude and merely happens to enable Copilot too. The
exclusion is therefore documented (option description + this fragment), matching
how Codex's missing LSP surface is handled — excluded and documented, not
asserted.

### What would change this decision

- Upstream adds project-scope config discovery, or a second injection flag →
  drop the inert-file caveat and deliver them properly.
- Upstream splits auth/session out of `COPILOT_HOME` → the env-var route becomes
  viable and would remove the wrapper.
- Copilot stops accepting `@`-prefixed paths → the whole delivery mechanism
  changes; the module-eval test asserting the emitted flag will catch it.

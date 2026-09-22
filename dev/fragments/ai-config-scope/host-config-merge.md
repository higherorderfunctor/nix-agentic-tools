## Devenv runtimes merge with host config — the reason is auth, not tidiness

> **Last verified:** 2026-09-21 (commit pending — Kimchi's devenv facet now
> writes the native project paths instead of a HOME-shaped subtree). Kimchi
> keeps reading user config, and its `configDir` remains a Home Manager output
> option (the pinned runtime discovers only its default). Copilot is the only
> runtime that needs an additive flag instead of native project merge.
>
> States as one cross-runtime rule what previously had to be inferred by reading
> three factories side by side: no `ai.*` runtime redirects its config root, on
> either backend, and the reason is identical in every case. Motivation hoisted
> from the measurement already recorded in
> `dev/fragments/ai-clis/copilot-config-delivery.md`, which stated it only for
> Copilot. If you add a runtime, change how one delivers config, or set any
> `*_HOME` / `*_CONFIG_DIR` variable in a wrapper, update this fragment in the
> same commit.

### The rule

A runtime delivered by `devenv shell` reads the developer's user-global config
**in addition to** what this repo writes. Nothing isolates a runtime from its
host configuration, and no `ai.*` code path sets a config-root variable.
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME` and `KIRO_HOME` are _read_
(always with a `$HOME` fallback) and never _written_.

This is a deliberate choice with a specific motivation, not an accident of
incompleteness. Do not "fix" it by pointing a config root at the project.

Verify from inside the shell — every value must be empty:

```bash
for v in CLAUDE_CONFIG_DIR CODEX_HOME COPILOT_HOME KIRO_HOME; do
  printf '%-20s %s\n' "$v" "$(printenv "$v" || echo '<unset>')"
done
```

### Why: these tools keep credentials and history under the config root

Every one of these CLIs stores **account state, credentials and conversation
history in the same directory tree as its declarative config.** Redirecting that
root to a project directory forks authentication per project and writes session
transcripts into the repository.

Measured for Copilot, where a single variable moves the entire tree:

```text
$COPILOT_HOME/config.json          # auth / account state
$COPILOT_HOME/session-store.db     # + -wal, -shm
$COPILOT_HOME/session-state/…      # full conversation history
$COPILOT_HOME/logs/…
```

`COPILOT_HOME` _works_ — it does relocate `mcp-config.json` lookup and does stop
the `$HOME/.copilot/` read. It is refused anyway, for the cost above.

The corollary that is easy to miss: because the constraint is about auth and
history rather than about config, a runtime that can add config **without**
moving its root is free to do so. That is the only reason Copilot needs a
different mechanism from the rest.

### Per-runtime mechanism

| runtime   | host root read      | what devenv adds                                                                                                       | mechanism                                                   |
| --------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `claude`  | `~/.claude/`        | `<repo>/.claude/settings.json`, `.mcp.json`, `CLAUDE.md`                                                               | native project scope — the CLI merges user + project itself |
| `codex`   | `~/.codex/`         | `<repo>/.codex/config.toml`                                                                                            | native project scope — the CLI merges user + project itself |
| `copilot` | `~/.copilot/`       | project `mcp-config.json`                                                                                              | additive wrapper flag `--additional-mcp-config @<path>`     |
| `kimchi`  | `~/.config/kimchi/` | root `AGENTS.md`, `.kimchi/config.json`, `.kimchi/mcp.json`, `.kimchi/skills/`, `.config/kimchi/harness/settings.json` | native project scope; see trust exception below             |
| `kiro`    | `~/.kiro/`          | `<repo>/.kiro/{steering,hooks,agents,settings}/`                                                                       | native project scope via a repo-relative `configDir`        |

Codex used to be the one that needed explaining: `ai.codex.profiles` had no
additive-flag equivalent, so adding a named profile meant writing a whole extra
file into the user's own `CODEX_HOME`, guarded by a `flock` and a manifest keyed
by a hash of the git common directory. That surface was removed 2026-09-19 as
unreachable dead code (see the Settled bullet in
`dev/fragments/ai-module/ai-module-fanout.md`). Codex's devenv facet now only
ever writes into the project directory, so it needs no more explanation than
Claude or Kiro.

### What this rule does NOT cover

**Process environment is scoped; config is not.** `environmentVariables` and
`ai.shell` are delivered through each runtime's _wrapper_, so they reach only
the launched process. They are deliberately not routed through devenv's `env`
attrset, which writes the project **shell** and would leak every variable into
the developer's interactive session and everything else running in it. That is
process-scope containment and it is orthogonal to config scope — do not cite one
as evidence about the other.

**Kimchi's project trust is a delivery dependency.** pi derives its project
`CONFIG_DIR_NAME` from Kimchi's packaged
`piConfig.configDir = ".config/kimchi/harness"`, independent of the consumer's
Home Manager `ai.kimchi.configDir` output option. Pinned Kimchi discovers only
that option's default user location; a non-default value requires a compatible
package override. Devenv therefore writes harness settings to the fixed project
directory. Project config, MCP, skills, and harness settings stay inert until
explicit or persisted trust; unattended use can set user-scope
`harnessSettings.defaultProjectTrust = "always"` through Home Manager. The
project cannot grant itself trust.

Project-root `AGENTS.md` is the upstream exception. Kimchi's prompt-enrichment
extension directly walks ancestor context files without consulting the project
scope gate, so do not claim that file is inert before trust.

### What would change this decision

- A runtime splits auth and session state out of its config root → the env-var
  route becomes viable for that runtime and the wrapper can be dropped.
- A runtime gains an additive config flag → it moves from the materialize shape
  to the Copilot shape.
- The isolated-harness work lands → that harness owns isolation explicitly, and
  this rule then describes the default path rather than the only one.

Until one of those happens, treat a proposal to redirect any config root as a
proposal to fork the developer's authentication, and price it accordingly.

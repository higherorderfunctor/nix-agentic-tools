# Session state — labs / fixtures (agent-primitive labs)

> **Handoff artifact.** Written 2026-07-21 so three concurrent sessions can be
> unified. Self-contained: a reader with zero context should be able to act on
> this without asking me anything.
>
> **Convention for the other two sessions:** write yours to
> `docs/plans/session-state/<topic>.md` in the MAIN checkout
> (`/home/caubut/Documents/projects/nix-agentic-tools`), same section order,
> so the merge session can diff them side by side.

## 1. Identity and scope

**This session = the fixture/lab implementation** — a clean-room harness for
manually experimenting with agentic primitives (skill triggering, model/effort
selection, subagent orchestration, tool-intercepting hooks) against the real
Claude and Kiro CLIs.

**Why it exists:** testing "does my skill trigger?" is meaningless against the
real user-global config, which carries the `superpowers` family, `stack-*`,
`living-workflow`, ~20 MCP servers and a large `CLAUDE.md`. The lab is a clean
room where the primitive under test is the only thing present. **The Nix modules
are the delivery mechanism, not the subject.**

**Explicit non-goal:** a regression/assertion layer. No `checks/` entries, no
golden files. Deferred until the labs produce something worth locking down.

## 2. Where everything is

| Thing               | Path                                                                               |
| ------------------- | ---------------------------------------------------------------------------------- |
| Worktree (ALL code) | `/home/caubut/Documents/projects/nix-agentic-tools-worktrees/agent-primitive-labs` |
| Branch              | `refactor/agent-primitive-labs`                                                    |
| Branch point        | `010dbe15` (on `refactor/ai-factory-architecture`)                                 |
| Design spec         | `docs/plans/agent-primitive-labs-design.md` (main checkout, untracked)             |
| Impl plan           | `docs/plans/agent-primitive-labs-impl-plan.md` (main checkout, untracked)          |
| Execution ledger    | `<worktree>/.superpowers/sdd/progress.md`                                          |
| Per-task reports    | `<worktree>/.superpowers/sdd/task-N-report.md`                                     |
| Kiro probe rig      | `/var/tmp/nat-kiro-probe/` (left in place, reproducible)                           |
| Materialized lab    | `/var/tmp/nat-labs/hello/`                                                         |

Docs are canonical in the **main checkout**; code is in the **worktree**. That
split was deliberate — do not copy docs into the worktree.

## 3. Commits (worktree is clean; nothing uncommitted)

```
a4560b77 fix(labs): narrow the activation-absence match to the verified phrasing
30106d0e fix(labs): fail closed on activation-eval errors and add --reset
1520bafe style(labs): use parameterized, dropping an avoidable cspell term
f9890573 feat(labs): add lab-up.sh materializing the fake user-global
96b72778 fix(labs): give the hello lab a non-empty settings so settings.json emits
df6a3392 feat(labs): add home-manager input and lab homeConfigurations discovery
```

Files touched vs `010dbe15` (+281 lines, no deletions):

```
config/cspell/project-terms.txt |   3 +
dev/scripts/lab-up.sh           | 161 +   (new)
devenv.lock                     |  22 +
devenv.yaml                     |   5 +
flake.lock                      |  22 +
flake.nix                       |  44 +
labs/hello/lab.nix              |  24 +   (new)
```

## 4. Status

| Item                                                                      | State                                                                |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Task 1 — `home-manager` input + `homeConfigurations.lab-*` auto-discovery | **DONE**, reviewed clean                                             |
| Task 2 — `dev/scripts/lab-up.sh [--reset] <name>`                         | **DONE**, reviewed + re-reviewed clean                               |
| Task 5 — skill-trigger lab (the actual first experiment)                  | **NOT STARTED** — the payload                                        |
| Task 6 — Kiro `KIRO_HOME`/hooks HITL probe                                | **PARTIALLY DONE** — main question answered, one control outstanding |
| Task 3 — generated devenv project scope                                   | **CUT** (retained in plan, marked)                                   |
| Task 4 — lifecycle verbs                                                  | **CUT** — folded into `lab-up.sh --reset`                            |

**Working deliverable today:**

```bash
dev/scripts/lab-up.sh [--reset] hello
cd /var/tmp/nat-labs/hello/work     # direnv exports the isolation contract
claude
```

Verified: `settings.json` present + writable, trust gate seeded, **zero dangling
symlinks**, `nix flake check --max-jobs 1` green, `shellcheck -x` clean.

## 5. Empirical findings — the reusable part

These were verified by `strace`, binary inspection, and live probes. **They are
the highest-value output of this session and bear directly on the other two.**

### 5.1 Claude config isolation (CONFIRMED)

| Lever                                               | Effect                                                                               |
| --------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `CLAUDE_CONFIG_DIR`                                 | relocates the entire Claude user scope                                               |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR=` (set, **empty**) | pins creds to the real `~/.claude` → **auth survives a full config redirect**        |
| `KIRO_HOME`                                         | relocates Kiro's `agents/ settings/ skills/ steering/`; auth unaffected              |
| `XDG_DATA_HOME`, `HOME`                             | **never set** — both destroy Kiro's auth DB (`~/.local/share/kiro-cli/data.sqlite3`) |

### 5.2 Settings have NO ancestor walk; `CLAUDE.md` does (CONFIRMED, `strace`)

Claude resolves exactly four settings paths (user scope, `<cwd>/.claude/settings.json`,
`<cwd>/.claude/settings.local.json`, `/etc/claude-code/managed-settings.json`).
But `CLAUDE.md` walks **every ancestor, two probes per level, up to `/home`** — so
any cwd under `$HOME` loads the real `~/.claude/CLAUDE.md` regardless of
`CLAUDE_CONFIG_DIR`. **This is why labs live in `/var/tmp/`, not under `$HOME`.**
No env var fixes it (`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` also kills the lab's own).

### 5.3 Kiro V3 does NOT load global hooks (CONFIRMED — ⚠ see 5.3.1)

Probe: two identical v3 envelopes, **both real files (not symlinks)** —
`$KIRO_HOME/hooks/probe-global.json` and `<cwd>/.kiro/hooks/probe-local.json`.
The TUI's `/hooks` listed **exactly 2, both local**. The real
`~/.kiro/hooks/kiro-memory.json` (4 hooks) also did not appear.

Unambiguous by elimination: if `KIRO_HOME` covers `hooks/`, the probe globals
should have loaded; if it does not, the real `~/.kiro` globals should have.
Neither did.

**Because the probe used REAL FILES on both sides, this is independent of the
symlink-vs-copy issue.** It is a _scope_ finding, not a delivery finding.

Also: **V3 is the default in kiro-cli 2.13.0** (bare `kiro-cli` banners "Welcome
to Kiro CLI V3!"). `--tui`/`--v3` are launcher flags; there is no `tui`
subcommand; the devenv-scoped `kiro` wrapper rejects them — use `kiro-cli`.

#### 5.3.1 ⚠ NEEDS RE-VERIFICATION after `af53cf63`

This probe ran **before** rebasing onto `af53cf63 feat(kiro-cli): real-file HM
hook delivery + shared tui/v3 wrapper (both backends) (#433)`. That commit
changes both hook delivery and how Kiro is launched. The scope conclusion should
still hold (real files were used), but **the merge session should re-run the
probe rather than inherit the conclusion.** Rig is intact at
`/var/tmp/nat-kiro-probe/`.

### 5.4 devenv imposes no source boundary (CONFIRMED)

devenv 2.x generates no `.devenv/flake.nix`; the project root stays a raw
filesystem path (`resolve-lock.nix`: `outPath = src`). A devenv project outside
the repo can import repo modules by absolute path, and those files land in
`.devenv/input-paths.txt`, so repo edits invalidate the consumer's eval cache
live. (Used to justify cutting Task 3; may be useful elsewhere.)

### 5.5 Tooling gotchas worth propagating

- **`devenv tasks run <task> -- <arg>` has NO positional-arg channel.** Everything
  after `run`, including after `--`, is parsed as more task names. Only
  parameterization is `tasks.<name>.input` + `--input k=v` → `$DEVENV_TASK_INPUT`
  (JSON). Verified via `--help`, alternate shapes, and `strings` on the binary.
- **`statix` W20 fires at 3+ keys sharing a top-level prefix** in one attrset —
  three flat `ai.*` entries fail pre-commit; nest under one `ai = { … };`.
- **Nix 2.34.4's missing-attribute message is `does not provide attribute`**, NOT
  `does not exist`. Do not broaden an error-classification match to include
  `does not exist` — it appears in genuine module-system errors ("The option
  'foo.bar' does not exist.") and this repo renames options.
- **home-manager only emits `~/.claude/settings.json` when
  `cfg.settings != {} || cfg.marketplaces != {} || disabledMcpServerNames != []`**
  (`modules/programs/claude-code/default.nix:235`). A lab with no settings gets
  `CLAUDE.md` and nothing else.
- **`cp -rL` then `chmod -R u+w`** — `--no-preserve=mode` silently strips the
  exec bit off `.claude/hooks/*`.

## 6. Cross-session collision analysis

### 6.1 File overlap (mechanical)

My branch vs `010dbe15..88f1fc8b` (what landed on `refactor` meanwhile):

| File                              | Mine                                                                  | Theirs                           | Risk                                                                                                                        |
| --------------------------------- | --------------------------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `flake.nix`                       | +44 (`homeConfigurations`, `home-manager` input, `labNames`/`labDef`) | 92 changed, **mostly deletions** | **HIGH — the real conflict**                                                                                                |
| `config/cspell/project-terms.txt` | +3                                                                    | +8                               | LOW — both append; resolve by union                                                                                         |
| `devenv.lock` / `flake.lock`      | +22 each                                                              | 16 / 12 changed                  | MEDIUM — regenerate rather than hand-merge                                                                                  |
| `devenv.yaml`                     | +5                                                                    | +4                               | LOW — generated; regenerate via `nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml` |
| `dev/scripts/lab-up.sh`, `labs/`  | new                                                                   | untouched                        | NONE                                                                                                                        |

**Rebase, not merge.** My branch is +281 lines with zero deletions and no
dependency on anything they changed. Locks should be regenerated, not resolved.

### 6.2 Substantive overlap — this matters more than the file conflicts

Three sessions independently converged on **the same failure surface: Kiro/Claude
config that is silently not applied.**

- **Their session (a)** — `f12aa5f1 refactor(devenv): materialize instruction
files as copies, not symlinks`, `a7b3e29d fix(devenv): make generated-file
copies idempotent over devenv symlinks`, `88f1fc8b docs(kiro-cli): correct the
"steering loads fine as symlinks" claim`. → **delivery mechanism** (symlink vs
  real file).
- **Their session (b)** — `af53cf63 feat(kiro-cli): real-file HM hook delivery +
shared tui/v3 wrapper`, `cb223061 docs(typed-hooks): add build-typed-hook-surface
living plan`. → **hook wiring**.
- **This session (c)** — `KIRO_HOME` does not deliver global hooks _at all_, with
  real files on both sides. → **scope**, orthogonal to delivery.

**The unification insight:** (a) and (b) fix _how bytes reach the CLI_. (c) says
that for Kiro global hooks, **no delivery mechanism works, because the scope
isn't read.**

> **Correction (2026-07-21, from session (a) via the converged plan):** "(a)
> fixes how bytes reach the CLI" is only half true — `f12aa5f1` converted the
> REPO'S OWN generated files; the factory emitters (mkKiro steering/skills/
> agents, mkClaude) were deliberately NOT converted and still ship store
> symlinks to every consumer. Delivery is a third independent axis, not a
> solved one. Canonical status:
> `docs/plans/converge-agentic-foundations.md` § Verified base state. A symlink→copy fix does not make global hooks fire. If the
> typed-hook surface in (b) targets `~/.kiro/hooks/`, that needs re-verification
> against (c)'s finding before it is called done.

**Corollary flagged but NOT established:** `~/.kiro/hooks/kiro-memory.json` was
HM-delivered as a store symlink AND global — two independent failure reasons — so
auto-memory may have silently regressed when V3 became default. Evidence is one
probe in a throwaway repo with `KIRO_HOME` redirected. `af53cf63` may already fix
the delivery half. **Do not treat this as an established regression.**

## 7. What I need / what I offer

**Need from (a):** confirmation of exactly which surfaces moved symlink→copy, so
I know whether lab-materialized trees are affected (labs `cp -rL` anyway, so
probably not).

**Need from (b):** whether the typed hook surface targets global `~/.kiro/hooks/`,
workspace `<cwd>/.kiro/hooks/`, or both — (c)'s finding says global is inert.

**Offer to both:** §5 in full, especially 5.3 (scope ≠ delivery), 5.5 (the
tooling gotchas — the `does not exist` regex trap in particular), and the intact
probe rig at `/var/tmp/nat-kiro-probe/` for re-running against their fixes.

## 8. Recommended merge order

1. Rebase `refactor/agent-primitive-labs` onto current `refactor` HEAD
   (`88f1fc8b`+). Regenerate `devenv.yaml`, `devenv.lock`, `flake.lock` rather
   than resolving them by hand. Expect a real `flake.nix` conflict.
2. Re-run `nix flake check --max-jobs 1` before anything else.
3. Re-run the Kiro probe (§5.3.1) against the post-`af53cf63` tree.
4. Reconcile (b)'s hook target against §5.3.
5. Then Task 5 (skill-trigger lab) — unblocked and independent of all of the above.

## 9. Parked items

`P1`-`P13` live in the impl plan's **Parked items** section with full evidence.
Headlines: **P1** `ai.mcpServers` hard-broken on the devenv backend
(`mkClaude.nix:659`, README surface broken for every consumer); **P11** adopt
`nmt` for factory emission tests (prereqs already landed — `nix-lib-nmt-0.5.1` is
in the pinned nixpkgs, `home-manager` input landed here; would retire 3,723 lines
of stubs in `checks/module-eval.nix`); **P12/P13** the Kiro findings above.

That section is a **temporary staging area**, explicitly not a second backlog —
it should be routed into a real rolling backlog and then deleted.

## 10. Outstanding HITL

- **P13 control (staged, unrun):** `cd /var/tmp/nat-kiro-probe/work && KIRO_HOME=/var/tmp/nat-kiro-probe/home/.kiro kiro-cli`, then `/hooks`. Question: does `probesymlink-*` appear beside `probelocal-*`? Answers whether Kiro refuses symlinks for _workspace_ hooks too. May now be moot if (a)/(b) already settled it.
- **Rebase** — deferred at the user's request pending session unification.

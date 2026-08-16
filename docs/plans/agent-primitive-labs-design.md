# Agent-Primitive Labs — Design

Status: draft, awaiting review Date: 2026-07-20 Branch:
`refactor/ai-factory-architecture`

## 1. Purpose

A set of small, isolated environments for experimenting with agentic-workflow
primitives against the real Claude Code and Kiro CLIs. Each lab exercises
**one** idea:

- skill authoring — what actually makes a skill trigger, and trigger precisely
- dynamic model selection, and effort / thinking-level selection
- driving the Task tool and subagent orchestration
- hooks that intercept or short-circuit tool calls at known points

Labs leverage each harness's native features where they exist, and stand in a
local implementation where the two harnesses diverge.

### Why isolation is the whole point

Testing whether a skill triggers is meaningless against the developer's real
user-global config, which carries the `superpowers` family, the `stack-*`
skills, `living-workflow`, ~20 MCP servers, and a large `CLAUDE.md`. A lab is a
**clean room**: the primitive under test is the only thing present. The Nix
modules are the delivery mechanism, not the subject.

### Non-goals

- **Not** a regression suite. No `nix flake check` gate, no golden files, no
  assertions. Deferred until the primary objective produces something worth
  locking down.
- **Not** a home-manager activation test. Labs never run `activate` and never
  write to the real `$HOME`.
- **Not** a replacement for `checks/module-eval.nix`.

## 2. Empirical findings

Everything below was verified against the installed toolchain (claude-code
2.1.215, kiro 2.12.3, devenv 2.1.3+37e75f5, nix 2.34.4) — not inferred. Evidence
lives in the probe transcripts.

### 2.1 Config-root isolation

| Lever                                               | Effect                                                                                                                                                                                        | Confidence                                      |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `CLAUDE_CONFIG_DIR`                                 | Relocates the entire Claude user scope: `settings.json`, `CLAUDE.md`, `rules/ skills/ agents/ commands/ plugins/ projects/ sessions/ …`, `history.jsonl`, `.credentials.json`, `.claude.json` | CONFIRMED (decompiled resolver + `strace`)      |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR=` (set, **empty**) | Pins credentials and the keychain service name back to the real `~/.claude` → **auth survives a full config redirect**                                                                        | CONFIRMED (live `claude -p` returning `OK`)     |
| `KIRO_HOME`                                         | Relocates `agents/ settings/ skills/ steering/`; auth is unaffected (it lives in `~/.local/share/kiro-cli/data.sqlite3`)                                                                      | CONFIRMED (`strace`, in-binary changelog 2.3.0) |
| `XDG_DATA_HOME`                                     | **Do not set.** Moves `kiro-cli/data.sqlite3` → Kiro loses auth and all state                                                                                                                 | CONFIRMED                                       |
| `XDG_CONFIG_HOME`                                   | Affects only `~/.config/anthropic`. Zero effect on `~/.claude` or Kiro                                                                                                                        | CONFIRMED                                       |
| `--setting-sources user`                            | Drops project-scope settings functionally (files are still opened; filtering is post-read)                                                                                                    | CONFIRMED                                       |

### 2.2 The settings leak does not exist; the CLAUDE.md leak does

`strace` shows Claude resolves exactly four settings paths — user scope,
`<cwd>/.claude/settings.json`, `<cwd>/.claude/settings.local.json`, and
`/etc/claude-code/managed-settings.json`. **There is no ancestor walk for
settings.** A planted ancestor `settings.local.json` that existed was absent
from the resolved chain.

`CLAUDE.md` is the opposite. The walk probes **two paths per ancestor level**
(`<dir>/CLAUDE.md` and `<dir>/.claude/CLAUDE.md`) from cwd up to and including
`/home`:

```
/home/caubut/<lab>/…/CLAUDE.md
…
/home/caubut/.claude/CLAUDE.md      ← the real global instructions
/home/caubut/CLAUDE.md
/home/.claude/CLAUDE.md
```

`CLAUDE_CONFIG_DIR` does **not** suppress this — the real global `CLAUDE.md`
arrives via the ancestor walk, not the user scope.
`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` stops it but also suppresses the lab's own
`CLAUDE.md`, so it is not usable.

**Consequence — load-bearing:** labs must be materialized **outside `$HOME`**.
`/var/tmp/nat-labs/` satisfies this (persists across reboot, unlike `/tmp` on
systems with tmpfs `/tmp`). `$XDG_STATE_HOME` does **not** — it resolves under
`$HOME`.

### 2.3 devenv imposes no source boundary

devenv 2.x generates no `.devenv/flake.nix`. The eval entrypoint is
`.devenv/bootstrap/default.nix`, and `resolve-lock.nix` leaves the project root
as a raw filesystem path (`outPath = src` where `src = devenv_root`). There is
no flake store copy and no git-tracked-files filter.

Verified: a devenv project outside the repo can
`imports = [ /abs/path/to/repo/... ]` (relative and absolute behave identically,
producing byte-identical store paths), materialize
`.claude/{settings.json,CLAUDE.md,rules/*,skills/*}` correctly, and — critically
— the out-of-root files are registered in `.devenv/input-paths.txt`, so **edits
to repo modules invalidate the lab's eval cache live**.

This supersedes the `path:../..` flake-input approach, which would have cost ~70
MiB of `fetchTree` copying per eval (`.git` included), a 940-line lock, a
recursion hazard when nested, and a stale-eval-cache workaround.

**Caveat:** the lab's `devenv.yaml` must pin the same `devenv` input as the repo
(`github:cachix/devenv/5f1cf17be0fc48689bd0ecb810de6d2e06d259a1`) so the
`claude.code` module schema matches.

### 2.4 home-manager `home-files` is a usable fake global

`nix build` of a `homeConfigurations.<lab>` succeeded first try with no repo
changes. `home-manager` is the **only** new pin required —
`programs.claude-code` is home-manager upstream
(`modules/programs/claude-code/`), auto-imported by `modules/modules.nix` via
`readDir`. Rev `a02190edf9a79d8da191da75eced1ce1ae5e2408` is already pinned by
nixos-config and therefore already in the store.

Build **`config.home-files` directly**, not `activationPackage`:

| Target              | Time                           | Closure                                                    |
| ------------------- | ------------------------------ | ---------------------------------------------------------- |
| `config.home-files` | **0.9 s**                      | 222 MiB (222 of it `glibc-locales`, irrelevant after copy) |
| `activationPackage` | 8.3 s cold / 4.9 s incremental | 1.5 GiB (pulls the `claude` CLI itself)                    |

Emitted tree (verified contents, not just presence):
`.claude/{CLAUDE.md, settings.json, agents/, commands/, hooks/, rules/, skills/}`,
`.copilot/`, `.github/instructions/`, `.kiro/{settings,skills,steering}/`.

Notes that bite:

- **MCP servers do not land in `settings.json` or `.claude.json`.** Upstream HM
  ≥2.1.157 packs them into a synthetic personal plugin at
  `.claude/skills/claude-code-home-manager/.mcp.json`.
- **Copy with `cp -rL … && chmod -R u+w`.** `--no-preserve=mode` silently strips
  the exec bit off `.claude/hooks/*`.
- **Use `ai.programs.stacked-workflows.enable = true`, never raw skill source
  dirs.** Raw dirs contain relative symlinks
  (`references/*.md -> ../../../references/*.md`) that HM copies verbatim,
  making `cp -rL` hard-fail.
- `ai.claude.package = null` is rejected (`types.package`). To drop the 1.3 GiB
  tail, use `programs.claude-code.package = lib.mkForce null`.

### 2.5 What `home-files` does not contain

Activation-only writes, all `$HOME`-parameterized and self-contained (absolute
`/nix/store/…/bin/jq` etc.), so they can be replayed by evaluating
`config.home.activation.<name>.text` and piping to `bash` with `HOME` set to the
lab:

| Entry                     | Target                          | Payload                                                                                          |
| ------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------ |
| `claudeUnpinLaunchEffort` | `$HOME/.claude.json`            | `{"unpinFable5LaunchEffort":true,"unpinOpus47LaunchEffort":true,"unpinOpus48LaunchEffort":true}` |
| `copilotSettingsMerge`    | `$HOME/.copilot/settings.json`  | `{"model":"gpt-5"}`                                                                              |
| `kiroSettingsMerge`       | `$HOME/.kiro/settings/cli.json` | `{"chat.defaultModel":"auto"}`                                                                   |

Also absent: `home.sessionVariables` (a separate output), so the lab exports
`CLAUDE_CONFIG_DIR` itself.

## 3. Architecture

### 3.1 One lab is one file

```nix
# labs/effort-ladder/lab.nix
{
  description = "Does effortLevel survive a subagent hop?";

  # → homeConfigurations.lab-effort-ladder → config.home-files → fake user-global
  global = {
    ai.claude.nativeSettings.effortLevel = "xhigh";
    ai.skills.ladder = ./skills/ladder;
  };

  # → generated devenv.nix importing repo modules by absolute path
  project = {
    ai.claude.enable = true;
    # ai.instructions is listOf attrs (sharedOptions.nix:39), not an attrset.
    ai.instructions = [{text = builtins.readFile ./TASK.md;}];
  };
}
```

Both scopes in one file, so a lab reads as a single statement of intent. Either
may be omitted; a lab testing only user-scope primitives (the common case for
skills, model selection, and effort ladders) declares only `global`.

### 3.2 Two scopes, two mechanisms

```
labs/<name>/lab.nix
   │
   ├── .global ──→ flake: homeConfigurations.lab-<name>
   │                  └─ nix build …config.home-files   (0.9 s, cacheable)
   │                        └─ cp -rL + chmod -R u+w
   │                              └─ /var/tmp/nat-labs/<name>/home/.claude
   │                                    ↑ CLAUDE_CONFIG_DIR
   │                                    + replayed activation snippets
   │                                    + seeded .claude.json (trust gate)
   │
   └── .project ─→ /var/tmp/nat-labs/<name>/project/devenv.nix
                      imports = [ /abs/repo/lib/ai/sharedOptions.nix
                                  /abs/repo/packages/*/modules/devenv ]
                      └─ devenv materializes .claude/, AGENTS.md, … in place
                         (live — repo module edits invalidate the eval cache)
```

`homeConfigurations.lab-*` are auto-discovered from `labs/` by `readDir`, so
adding a lab is adding a directory — no flake edit.

### 3.3 Materialized layout

```
/var/tmp/nat-labs/<name>/
├── .envrc                 # use devenv + isolation exports
├── devenv.nix             # generated: imports repo modules by absolute path
├── devenv.yaml            # generated: devenv input pinned to match the repo
├── home/                  # writable copy of config.home-files
│   ├── .claude/{settings.json,CLAUDE.md,skills/,agents/,hooks/}
│   ├── .claude.json       # seeded: hasTrustDialogAccepted + unpin flags
│   └── .kiro/
└── work/                  # cwd for the session; seeds symlinked to labs/<name>/
```

Seeds are symlinked back into `labs/<name>/`, so editing a skill under test
during a session edits the tracked source directly. `home/` is a copy, not a
symlink farm — Claude writes to its config dir (`sessions/`, `history.jsonl`,
`projects/`) and the store is read-only.

### 3.4 Isolation contract

Exported by `.envrc`:

| Variable                          | Value               | Rationale                                                             |
| --------------------------------- | ------------------- | --------------------------------------------------------------------- |
| `CLAUDE_CONFIG_DIR`               | `$LAB/home/.claude` | clean-room user scope                                                 |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` | `` (set, empty)     | keeps auth working against the real keychain                          |
| `KIRO_HOME`                       | `$LAB/home/.kiro`   | clean-room Kiro scope                                                 |
| `HOME`                            | **unchanged**       | changing it moves Kiro's auth DB and trips Claude's redirect detector |
| `XDG_DATA_HOME`                   | **unchanged**       | moving it destroys Kiro auth                                          |

Location outside `$HOME` is what handles the `CLAUDE.md` ancestor walk (§2.2);
no env var can.

### 3.5 Lifecycle

| Command            | Effect                                                                                                                                                |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lab:up <name>`    | build `home-files`, copy + `chmod -R u+w`, replay activation snippets, seed `.claude.json`, generate devenv + `.envrc`, symlink seeds, print the path |
| `lab:down <name>`  | remove `/var/tmp/nat-labs/<name>/`; tracked source untouched                                                                                          |
| `lab:reset <name>` | `down` then `up` — discards session state, keeps the lab definition                                                                                   |
| `lab:ls`           | list defined labs and which are materialized                                                                                                          |

Then `cd /var/tmp/nat-labs/<name>/work` and run `claude` or `kiro` normally.

## 4. Known blockers (pre-existing, out of scope)

Both surfaced during probing, both independent of this work, both agreed to be
fixed separately.

1. **`packages/claude-code/lib/mkClaude.nix:659` — `ai.mcpServers` is
   hard-broken on the devenv backend.** The devenv branch passes the raw typed
   schema through; the HM branch renders first via `lib.ai.renderServer`
   (`:494`). Upstream `claude.code.mcpServers` has no `package` option, so:
   `error: The option 'claude.code.mcpServers.probe.package' does not exist`.
   Reproduced with the repo subtree copied in-root, so it is not a lab artifact.
   The repo never trips it because `devenv.nix:186` sets upstream
   `claude.code.mcpServers` directly, bypassing the documented surface — meaning
   **any consumer following the README hits this immediately.** _Impact:_ labs
   cannot declare `project.ai.mcpServers` until fixed. The `global` scope is
   unaffected (HM branch renders correctly).

2. **`devenvModules.default` does not exist** — the real attr is
   `devenvModules.nix-agentic-tools`. Wrong in `README.md:87`,
   `dev/docs/getting-started/{devenv,choose-your-path}.md`,
   `dev/docs/troubleshooting.md:55`,
   `devshell/docs-site/pages/devenv-header.md`, `checks/devshell-eval.nix`
   (itself dead code), and `dev/generate.nix:511`, which bakes the wrong name
   into _generated_ instruction files.

Unchased observation worth a follow-up: `ai.environmentVariables` evaluated
cleanly but appeared neither in the devenv shell env nor in the emitted
`settings.json`. `lib/ai/app/devenvTransform.nix:28` computes `envMerge`;
whether `mkClaude` consumes it on the devenv path was not traced.

## 5. Open items

- **Tracked `labs/` and the format gates.** Tracked files enter
  `checks.formatting` (a hard treefmt gate) and the pre-commit
  `cspell`/`statix`/`deadnix` chain. Lab prose is deliberately weird (it is
  prompt material), so `labs/` likely needs a cspell exclusion. Decide when the
  first lab lands rather than pre-emptively.
- **Kiro hooks under `KIRO_HOME`.** Whether `KIRO_HOME` covers `hooks/` is
  UNVERIFIED — it is absent from the in-binary changelog list and was never
  opened in a non-interactive run, consistent with v3 hooks firing only in the
  TUI. Needs a live TUI probe before a lab targets typed Kiro hooks.
- **Naming.** `checks/fixtures/` already exists and means "input data for eval
  assertions". `labs/` is used here to avoid overloading the word.

## 6. Deferred

CI regression. If a lab produces something worth locking down, the assertion
layer bolts onto the same directories — the tier-1b prototype under
`docs/plans/typed-hooks-research/tier1b-prototype/` already demonstrates
zero-registration fixture discovery with a declarative assertion vocabulary and
is the natural pattern to adopt.

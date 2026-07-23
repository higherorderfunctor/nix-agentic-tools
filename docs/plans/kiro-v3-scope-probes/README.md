# Kiro v3 scope probes (hooks / skills / agents / global)

Preserved, manually-runnable reproducers for **what Kiro v3 actually loads and
fires** — per surface (hooks, skills, agents), per scope (workspace vs global),
and, load-bearing for the factory, **real files vs store symlinks**. Verified
against `kiro-cli 2.13.0` on 2026-07-23.

> **Status: knowledge-capture, not the regression fixture.** These scripts drive
> a live Kiro TUI and spend the operator's real Kiro account, so they are
> **manual** reproducers, not CI tests. The hardened, hermetic regression
> fixture (nmt-integrated) is tracked as `oi-probe-fixtures-port` in the
> converge-agentic-foundations plan (phase P4). This directory exists so that
> work — and anyone re-checking a finding on a Kiro bump — starts from a working
> harness instead of reconstructing it.
>
> The older `docs/plans/steering-symlink-probe/run-probe.sh` is the
> steering-specific ancestor and is now **stale**: it passes `--tui --v3` by hand
> (the wrapper injects them now → clap aborts on the double) and uses the headless
> path (which skips the hook engine). Re-do the steering check by adapting
> `probe-hooks.sh` (workspace-steering re-verify is an open P3 agenda item).

## Run

```bash
./setup-rig.sh              # build the hook rig under /var/tmp/nat-kiro-probe
./probe-hooks.sh           # workspace + global hooks (real vs symlink) via the live TUI
./probe-global-realhome.sh # real-file vs symlinked GLOBAL hooks at the real ~/.kiro/hooks (additive, trap-cleaned)
./probe-skills-agents.sh   # skills + agents (real / symlinked-file / symlinked-dir), self-contained
```

Requires `tmux` and `kiro-cli` on PATH, plus a logged-in Kiro account.

## Four harness bugs (the expensive part — do not re-hit)

1. **`timeout … script -qec "…"` deadlocks in a live terminal.** `script` tries
   to arbitrate the controlling tty and never opens its typescript → exit 124,
   no output. Run from a no-controlling-tty context (`setsid`, or an agent shell),
   or drive the TUI with `tmux` instead.
2. **The `kiro-cli` wrapper appends `--tui --v3` unconditionally.** Passing them
   by hand doubles `--tui` and clap aborts (`cannot be used multiple times`). Pass
   only your own args; let the wrapper add the engine flags. (Fixed to be
   idempotent in PR #463, but a reproducer should still not pass them.)
3. **`--no-interactive` runs the model but SKIPS the hook engine.** v3 hooks fire
   only in the live TUI, per turn. A headless one-shot answers the prompt yet
   fires nothing — even the real-file control. You must drive a real interactive
   turn (hence `tmux`).
4. **The `/hooks` modal eats typed input as its filter.** Send the chat turn
   FIRST, capture `fired.log`, THEN open `/hooks` — otherwise your prompt lands in
   the modal's search box and no turn runs.

## Methodology

- **Drive a real TUI with tmux.** `tmux new-session -d … kiro-cli chat` launches
  a real pty; `tmux send-keys` injects the prompt and slash commands; `tmux
capture-pane` reads the screen. This runs the interactive-only hook path with
  no human at the keyboard.
- **Two signals.** _Firing_: hooks append a marker to `fired.log` when they run
  (ground truth). _Loading_: on-screen enumerations — `/hooks` (modal list),
  `/agent` (list/switch agents), `/context show` (lists steering + skill files).
  There is **no** `/skills` command.
- **Isolation.** `KIRO_HOME=<rig>/home/.kiro` redirects config/hooks/settings
  while leaving the auth DB (under `~/.local/share`) intact. Never set `HOME` or
  `XDG_DATA_HOME` (that kills the Kiro auth DB). Rigs live outside `$HOME`.
- **KIRO_HOME does NOT relocate the global-hooks path.** The 2.13.0 global-hooks
  loader reads the real `$HOME/.kiro/hooks`, so `probe-global-realhome.sh` tests
  global hooks by placing an additive, trap-cleaned probe there.

## Rig layout (`setup-rig.sh`)

```
/var/tmp/nat-kiro-probe/
  home/.kiro/hooks/probe-global.json      GLOBAL-*   (reached via KIRO_HOME)
  home/.kiro/settings/cli.json  = {}
  work/  (git repo)
    .kiro/hooks/probe-local.json          LOCAL-*    (real workspace file = control)
    .kiro/hooks/probe-symlink.json  ->  src/probe-symlink.json   SYMLINK-*
  fired.log                               markers appended here when a hook fires
```

## Settled findings (kiro-cli 2.13.0)

**v3 symlink handling is surface-specific — not universal:**

| Surface           | Symlinked file | Real file | How observed            |
| ----------------- | -------------- | --------- | ----------------------- |
| Hooks (workspace) | **dropped**    | loads     | `/hooks` + `fired.log`  |
| Hooks (global)    | **dropped**    | loads     | `probe-global-realhome` |
| Steering          | dropped\*      | loads     | model recites tokens    |
| Agents            | **follows**    | loads     | `/agent`                |
| Skills            | **follows**    | loads     | `/context show`         |

\* Steering-drop is inherited from the stale `run-probe.sh`; **re-verify** with a
tmux-driven probe before trusting it (hooks drop but agents/skills follow, so the
symlink rule is per-surface, and the old steering finding shares the harness bugs
above). Skill dir-symlinks and file-symlinks both loaded; the model reading files
via `fs_read` can mask the loader's behavior, so trust `/context show`, not a
"can you see skill X" question.

**Consequences for the factory:** hooks and steering must be delivered as **real
files** (copy materialization); agents and skills may stay cheap symlinks. Global
hooks read the real `~/.kiro/hooks` and honor real files — so `autoMemory`,
delivered there as a **store symlink** on the live system, is silently dropped
under v3; the on-branch real-file delivery restores it once activated.

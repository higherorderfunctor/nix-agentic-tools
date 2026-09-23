# Shell activation goes through direnv

> **Last verified:** 2026-09-23 — measured on devenv 2.3.2+87edd16 and direnv
> 2.37.1.
>
> **Settled — do not relitigate.** Replacing `.envrc` with `devenv hook` was
> evaluated over four measurement passes and rejected. `devenv hook` notices
> nothing at all while a shell is active, so the swap trades a next-prompt
> reload for a manual exit-and-re-enter. Transcripts:
> `dev/references/devenv-activation-probe.md`, and the header of
> `lib/traceSource.nix`.

**Decision: keep direnv. Do not delete `.envrc`. Do not migrate to
`devenv hook`.**

## `devenv hook` is activation-only — it watches nothing

`_devenv_hook` returns at its first statement when `DEVENV_ROOT` is set. Inside
an active devenv shell it therefore notices no change at all, **not even an edit
to `devenv.nix`**. It never reads `.devenv/input-paths.txt`. Its only refresh
point is leaving the shell and re-entering it, where devenv's content-hashed
eval cache decides whether to rebuild. Measured across 24 activations, with
12/12 no-change controls and two independent detector signals agreeing on
all 24.

direnv, by contrast, reloads at the next prompt. That is the capability the
migration would give up.

Timings, same machine, same day: cold re-entry under `devenv hook` 15-20s, a
direnv cache hit 0.01s, a direnv reload 14-18s.

This holds for zsh as well as bash — re-derive it rather than trusting the
figures, since they came from a direct comparison of the two generated scripts
and not from the probe transcript:

```bash
diff <(devenv hook bash) <(devenv hook zsh) | grep -c '^[<>]'   # 13
devenv hook zsh | grep -n 'DEVENV_ROOT:-'                       # 30
```

The 13 differing lines are all the registration tail (bash's `PROMPT_COMMAND`
versus zsh's prompt-command array) plus one `_DEVENV_SHELL_HINT` value, and the
`DEVENV_ROOT` early return is line 30 in both.

## Migrating would be a REMOVAL, not an addition

Both hooks are commonly installed at once, and direnv silently wins. A shell rc
that runs `direnv hook <shell>` before `devenv hook <shell>` gives direnv the
first prompt; `use devenv` sets `DEVENV_ROOT`; the devenv hook then no-ops on
every prompt after. `DEVENV_DIRENVRC_VERSION` present in the environment is the
tell that activation came through direnv.

So "switch to `devenv hook`" means deleting something — `.envrc` here, or the
direnv line in the shell rc — not adding anything. `.envrc` is not leftover
scaffolding sitting next to a newer mechanism.

## The two mechanisms key on opposite things

The two columns below are not like-for-like in time, so the frame is named in
each heading rather than left implied. While a shell is live, direnv's only
refresh point is the next prompt, and `devenv hook` has none at all — nothing it
could notice, so nothing to compare against in-frame. Its only moment is exiting
and re-entering, where devenv's eval cache decides. Whether a given change
actually triggers anything at that point is what the table answers, and the
answers differ per row. So read every row as: what direnv does at your next
prompt, versus what `devenv hook` does the next time you re-enter.

| Event                          | direnv, at the next prompt | `devenv hook`, at re-entry |
| ------------------------------ | -------------------------- | -------------------------- |
| `touch`, bytes unchanged       | reloads                    | no rebuild                 |
| Content edit, mtime restored   | no reload                  | rebuilds                   |
| A file ADDED to a watched tree | missed                     | caught                     |

direnv triggers on mtime; `devenv hook` triggers on content, through the eval
cache. Neither is a superset of the other. The mtime keying is what makes direnv
noisy, and it is also what makes in-shell reload possible at all.

Every cell above is a single trial, because each row is a mechanism rather than
a rate. The mechanism behind the third row is directly observable: at a cold
load direnv held 593 watches and not one of them was a directory, so an added
file has no listing-level watch to trip. The add was missed in both probe trees.

## It is what keeps `lib/traceSource.nix` load-bearing

direnv's watch list is that module's only remaining consumer. Under
`devenv hook`, a bare store copy (`env.X = "${./dir}"`) already picks up a
content edit on re-entry with no help — measured 3/3, and the traced twin
behaves identically, 2/2. A migration would therefore turn that module into dead
code. Its header carries the full reasoning, the census of every dependent that
would go with it, and the ablation recipe for confirming the deletion; read it
there rather than restating it here.

## Documented, NOT measured here

devenv's own docs
([guide](https://devenv.sh/guides/using-with-flakes/#caching-devenv-up-with-direnv))
state that under direnv, `devenv up`, `devenv test` and `devenv tasks` skip
re-evaluation and use the cached environment, starting significantly faster.
This repository has not measured that. An attempt with `devenv tasks list` was
**inconclusive**: that subcommand does not evaluate at all, taking 0.05s either
way. A discriminating test needs `devenv up`, `devenv test` or
`devenv tasks run`, all of which mutate, and it was not run. Treat the speedup
as a documented claim, not as evidence. It points the same direction as the
decision, so nothing here rests on it.

## What would change the decision

- **devenv gains in-shell reload.** That is the one capability direnv is kept
  for. If the hook ever watches while a shell is live, the mtime noise becomes
  pure cost and the swap is worth re-running.
- **The `devenv up` caching claim gets measured.** If it turns out negligible,
  direnv's case rests on in-shell reload alone — a thinner margin than today's
  two-reason case looks.

Both are re-measurable. Neither is true today.

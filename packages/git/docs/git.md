# The `git.*` option root: typed git configuration on both backends

> **Last verified:** 2026-09-29 — `git.settings` plus `git.branchless`,
> `git.absorb` and `git.revise` on Home Manager and devenv; devenv keeps its
> include last and runs `git branchless init` on every entry.
>
> **Settled — do not relitigate.**
>
> - **The devenv include goes LAST, repaired on every entry** (operator
>   decision, 2026-09-29). Prepending it as the lowest repository-local layer
>   was proposed and rejected: then `branchless/config` beats every key NAT
>   sets, so each init-owned key needs its own reconciliation, and a user's
>   stale hand edit silently wins forever. Last means NAT wins for exactly the
>   keys it sets and nothing else. `git config --add include.path` cannot do it:
>   it inserts into the existing `[include]` section.
> - **No "already initialized" guard on init.** `.git/branchless/` exists after
>   a failed init and after any earlier branchless command, so a directory test
>   skipped init forever (measured). Init is idempotent; it runs every entry.
> - **Configuration reaches git-branchless and git-absorb only through files.**
>   Their libgit2 ignores `git -c`, `GIT_CONFIG_*` and `GIT_CONFIG_GLOBAL`
>   (measured); user-global means `$HOME` / `$XDG_CONFIG_HOME`.

## Owners

| Path                                             | Owns                                                                                                 |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `packages/git/modules/`                          | `git.settings`: HM alias of `programs.git.settings`; devenv option + `git:config` task               |
| `packages/git-{absorb,branchless,revise}/`       | `modules/options.nix`: `git.<section>.{enable,settings}` through the factory below                   |
| `packages/git-branchless/modules/`               | `scopedSync`; devenv `git:branchless-init`; per-backend `test.jobs` checks                           |
| `lib/git-tool-settings/tool-module.nix`          | the factory: option tree + the ONE lowering into `git.settings` + package install                    |
| `lib/git-tool-settings/ini-type.nix`             | Home Manager's `gitIniType`, shared by devenv's option and both HM stubs                             |
| `lib/git-tool-settings/repo-config.{sh,nix}`     | `nix-agentic-tools-git` (`include`, `init`), run by the tasks and by `checks/git-config/runtime.nix` |
| `packages/stacked-workflows/modules/options.nix` | `gitPreset`: `mkDefault` sugar over all of the above                                                 |

Owners share code only through `lib/`; the tool modules reach the git layer by
setting `git.settings`, never by importing it.

## Lowering (one renderer)

A typed leaf `git.<section>.settings.<path>` is the git key `<section>.<path>`.
The factory writes every non-null leaf (non-empty for a `<name>` family) into
`git.settings` as `mkOverride opt.highestPrio opt.value`, in git's
`section.subsection.key` shape: middle segments join into one dotted subsection,
and a family is its own subsection (`branchless."test.alias".<n>`, the only
shape `gitIniType` admits). Consequences, all checked:

- A preset value (`mkDefault`) yields to any raw `git.settings` /
  `programs.git.settings` value; an explicit typed value that disagrees with a
  raw one is a definition conflict; agreeing values merge.
- A family carries one priority: that of its highest-priority whole-map
  definition. Per-name `mkDefault` inside a map is lost; set the map.
- Null writes nothing. Nothing can unset a lower scope's key; `""` is a value.

## Home Manager

`git.settings` is
`mkAliasOptionModule ["git" "settings"] ["programs" "git" "settings"]`, which
forwards definitions with their priorities. Home Manager renders nothing while
`programs.git.enable` is false, so any non-empty `git.settings` definition then
warns. HM cannot initialize repositories:
`git.branchless.settings.core.mainBranch` user-global only matters where init
has not written a repository value, and `scopedSync` needs a re-run of
`git branchless init` in repositories initialized before it (init skips its own
`alias.sync` only when a global one exists).

## devenv

`git.settings` (type `gitIniType`) → `toGitINI` → a store file. On every entry:

1. `git:branchless-init` (when `git.branchless.enable`), before `git:config` and
   `devenv:git-hooks:install`: `git -C "$DEVENV_ROOT" branchless init`, with
   `--main-branch` from the typed value, else the value `branchless/config`
   already records (init without it re-detects and overwrites). Skipped with a
   notice when HEAD is unborn or the primary repository is bare (init given
   `--main-branch` was measured to succeed in both; they are skipped by
   decision). Any other failure fails the task.
2. `git:config`: publishes `<common>/nix-agentic-tools.gitconfig` (0444,
   same-directory rename) and, unless
   `include.path = nix-agentic-tools.gitconfig` is already the last entry of
   `<common>/config`, removes it and appends a trailing `[include]` section. The
   rewrite follows git's lockfile protocol (exclusive `config.lock`, rename over
   it, rename over the config), so a concurrent `git config` fails instead of
   losing a write. Empty `git.settings` removes the include and the file;
   outside a repository that is a no-op. The path is relative, so it resolves
   from every linked worktree.

Both hold `flock` on `<common>/.nix-agentic-tools-git.lock`.

A failing task does not block shell entry. Measured with devenv 2.4.1: the entry
reports `Running tasks (failed)`, every task ordered after the failed one is
skipped as "dependency failed" (the `devenv:enterShell` task node included), and
the shell still starts and exits 0. So a failed init skips `git:config` and
prek's hook installation for that entry; the next entry retries both.

## Per-key contract

system < XDG `git/config` < `~/.gitconfig` < repository config with includes
expanded in place (NAT's last) < `config.worktree`. Last occurrence wins, the
same in git and libgit2. So devenv beats Home Manager key by key, in every
linked worktree; a hand edit of a key NAT sets wins until the next entry; keys
NAT does not set fall through.

## scopedSync

`alias.sync = "branchless sync 'stack()'"`. No `branchless.*` key can scope bare
sync (it never evaluates a revset; builtins shadow revset aliases). On main it
does nothing; `git sync X` is `stack() | X`; it still rebases onto LOCAL main,
so from a linked worktree whose primary holds main it usually does nothing and
`--pull` fails once `origin/main` moved.

## Checks

`checks/git-config/module-eval.nix` (option parity, stub realism, null, dotted
families, priorities, HM warning, int ranges, alias names, `test.jobs` coupling,
scopedSync, installs, task graph, task shellcheck) and
`checks/git-config/runtime.nix` (real repositories with the three tools: per-key
precedence for git, git-branchless and git-absorb, identical values, init and
main branch, toggling, hand edits, scoped sync, unborn, retried init, linked
worktree, bare primary, lock ownership, concurrency). Preset-specific checks
stay in `packages/stacked-workflows/checks/module-eval.nix`.

## Adding a tool

Its owner exports `lib.<owner>.settings` (see the git-tool-settings fragment),
adds `modules/options.nix` calling `tool-module.nix`, and two backend
`default.nix` files importing it. The parity and install checks list the tool
sections explicitly; extend them.

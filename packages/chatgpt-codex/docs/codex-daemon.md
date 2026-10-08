# Codex's app-server daemon: Home Manager selects its package

> **Last verified:** 2026-10-08 — launcher flags are checked as root-command
> `uses`; Home Manager owns daemon selection and settings; both backends run the
> offline project-document and project-config preflight before it execs the
> original binary, isolated by the shared `lib/ai/launcher-preflight.nix`.

Since 0.157 Codex runs a shared background app-server daemon. It always runs
`$CODEX_HOME/packages/app-server-daemon/current`, never the CLI that launched
it. Left to upstream, the first start copies the invoking package into
`releases/`, and an hourly updater then replaces it from GitHub, so a Nix bump
never reaches the process that runs every tool call.

## Home Manager pins it (`ai.codex.pinDaemonToPackage`, default on)

- **The pin.** Activation (`lib/daemonSelect.nix`) points `current` straight at
  `<package>/libexec/codex` and removes any `auto-update-version` marker. A
  selection outside `releases/` with no marker never qualifies for the updater.
  `updater.autoUpdateEnabled = false`, the pin's default in
  `ai.codex.native.daemonSettings`, is the second guard.
- **Upstream's lock.** The selection runs under upstream's daemon operation lock
  (`app-server-daemon/daemon.lock`), which every lifecycle command and the
  first-start copy take. It is released before the stop, because `stop` takes it
  too. If the lock stays busy past the wait, activation warns and selects
  anyway.
- **On a switch.** A changed target retargets first (atomic rename), then runs
  `daemon stop`; an unchanged target does nothing. It never restarts (see
  Settled). A failed or timed-out stop only warns and is not retried; the
  warning names the `CODEX_HOME=… <codex> app-server daemon stop` to run.
- **The time bound is activation's, not upstream's.** Home Manager's NixOS
  module runs ALL of activation in one unit with `TimeoutStartSec = 5m`; a
  selector that outlives it gets the unit killed, failing the switch and
  skipping every later entry. So the selector's worst case (lock wait + stop +
  `--kill-after`) is asserted at eval time to stay within 120s. A default stop
  (60s grace + 10s force) fits; a user who raised `shutdown_grace_seconds` can
  outlast it, and then `timeout` ends only the CLI and the warning says the
  daemon may still be running.
- **Release only what it wrote.** Disabling Codex or the pin removes a `current`
  of the exact shape the selector writes, `<store>/<name>/<root>`, so GC cannot
  leave it dangling. Any other `current`, such as a `home.file`-managed link, is
  left alone. `<root>` has one source, `lib/packageLayout.nix`: `package.nix`
  installs there, the selector builds its owned shape from it, and `mkCodex.nix`
  refuses to pin a package whose `passthru.codexPackage.root` differs, since it
  could never release it.
- **The opt-out.** `false` restores upstream's copy and updater. The copied
  executables are this source build's, and its voice and zsh resources are
  patched to the nix glibc; both link against store paths nothing roots from the
  copy, so it breaks after GC until the updater replaces it.
- **Auto-start is off** (`features.daemon_auto_start` defaults to false; users
  can opt in). A daemon keeps the environment of whoever started it and serves
  every later client with it. With sessions open across direnv or devenv
  projects, the first launch would define every session's tool environment.

## Home Manager owns its settings (`ai.codex.native.daemonSettings`)

`app-server-daemon/settings.json` is all configuration: `remoteControlEnabled`,
`featureOverrides`, `shutdownGraceSeconds` and `updater`. Home Manager always
writes it from `native.daemonSettings`, `{}` when nothing is declared, through
the `materialize-codex-daemon-settings` writer. That writer claims only this
file in the directory, beside the lock and pid files the daemon keeps there, and
runs while Codex is disabled so a disable retracts it.

It is a read-only copy, not a symlink, because Codex saves the file by writing a
temporary and renaming it over the path (`settings.rs`), which replaces a link
with a real file and fails the next switch's link check. A save
(`codex app-server daemon enable-remote-control`, or a start with launch feature
overrides that differ from the stored ones) therefore succeeds, and lasts until
the next activation backs it up and restores the declaration.

## devenv never touches daemon state

Its launcher always passes `--no-daemon`, the only flag that skips auto-start
AND refuses to attach to a running daemon. Tools see the project shell, and the
devenv-pinned version is what runs. `daemon_auto_start = true` or any
`native.daemonSettings` in devenv is an assertion, not a silent no-op;
`pinDaemonToPackage` is Home Manager-only and does not exist under devenv at
all, so declaring it there is an unknown-option evaluation error rather than a
rejected value. With the flag, `codex agents`, `codex queue` and `--remote`
refuse to run; `codex remote-control` and `codex app-server daemon …` ignore it
and still reach the user daemon. A VM or sandbox home is out of scope: the
sandbox will own that home.

## Every module launcher checks project documentation and config

Home Manager and devenv always install a launcher. It sets the configured
process environment, runs `lib/projectDocPreflight.nix`, then execs the original
package binary. `lib.ai.mkLauncher` preserves that binary's package as
`launcherPackage`; selecting an existing launcher flattens it rather than
nesting wrappers and running the preflight twice.

`debug prompt-input` needs no auth and succeeds in an offline Nix sandbox.
Measured on 0.161.0 with an empty Codex home: five repo calls took 34.5, 23.0,
23.3, 23.6 and 22.9 ms; five empty-git-repo calls took 22.6, 22.2, 22.7, 23.5
and 24.3 ms. It is still unsuitable for a launcher preflight: it creates a
session and starts network and MCP prewarming. `strace` showed DNS queries to
`api.openai.com`; an advisory launch check must not start those connections or
configured MCP processes.

The preflight therefore reads local files. The existing
`effectiveProjectDocMaxBytes` resolver parses TOML, accounts for system, user,
profile, trusted-project and session limits, handles lowered limits and clone
trust inherited by linked worktrees, and returns the root-to-cwd directories and
override/default/fallback filenames. Unix managed settings come from
`/etc/codex/managed_config.toml`; a same-named Codex-home file is ignored.
Custom-root trust gates project config, while only cwd/Git-clone distrust
suppresses project docs. The preflight measures the cumulative budget,
respecting empty overrides, whitespace-only content and explicitly untrusted
projects (which Codex does not load). Config, profile and cwd flags reach the
resolver; extracted CLI value requirements skip unrelated arguments, and `--`
ends option parsing. Unknown flags skip the advisory rather than guessing what
value they consume. Remote-session and managed-worktree launch paths are not
predicted; the check measures the local launch directory.

Warnings go only to stderr and name `project_doc_max_bytes` and
`ai.codex.projectDocMaxBytes`. The resolver adds the user-config trust remedy
when a skipped project config raises the limit. Missing/unreadable files,
invalid config and resolver failures are silent.

The same preflight runs the two project-config notices for every
`.codex/config.toml` in the resolver's root-to-cwd directories, skipping the
user config where the walk reaches it: `codex-project-trust-notice` warns when
Codex will ignore the file because nothing trusts the project, and
`codex-permission-layers-notice` warns when its permission model opposes the
user config's. They used to run at devenv shell entry, which Home Manager-only
users never reach. A resolver failure skips them with the rest of the preflight.
The document warnings print first, so per-config notice processes cannot push
them past the launcher's one-second bound, and each trust notice takes its
directory's trust from the preflight's one `--json` resolution
(`directory_trust`) instead of running the resolver again. Those notices run
nearest layer first, so the bound cuts the farthest layers.

`lib/ai/launcher-preflight.nix` isolates the whole preflight, for this launcher
and Kimchi's: a one-second timeout over its process group, no stdin, stdout
discarded, failure ignored. So it cannot change Codex's stdout or exit status.
It runs in repositories without devenv too. The devenv shell-entry notices and
manual `enterTest` prompt probe are deleted; `instructions-drift` still checks
the generated index and rule marker offsets. The
`chatgpt-codex-project-doc-preflight` check calibrates every discovery fixture
against the real binary's prompt builder in the offline Nix build sandbox, and
tests both backend launchers and failure isolation, including preflight checks
that fail, read stdin or hang with a child. `module-codex-launch-config-notices`
runs both notices' fixtures through each backend's launcher.

## Gates

- `checks/chatgpt-codex-daemon-selection.nix` runs the rendered activation
  against the real daemon: pin, unchanged re-pin under a held lock, simulated
  bump, unpin, and a foreign `current` that survives, with the settings copy
  read-only at each step. A store-path `current` is outside upstream's
  documented layout, so a release that stops honoring it fails there, in its
  update PR. It then drives the warn paths with stub roots and a selector whose
  waits are shortened through `.override`: a stop that fails, one that hangs,
  and a lock held past the wait each exit 0 with a `warning:`.
- `--no-daemon` lives in `lib/launcher-flags.nix`'s `devenv` list, which
  `mkCodex.nix` builds the launcher from. `extract/rules.nix` checks it as a
  `uses` dependency of the root command's flags, so `chatgpt-codex-extracted`
  fails with `removed` if upstream drops it from the root command.

## Settled — do not relitigate

- **`codex app-server daemon update --from-cli --yes` is not the pin.** Probed
  2026-09-26 on 0.157.1: each run copies about 374 MB into
  `releases/local-<blake3>-<target>`, which is never pruned; the copy's patched
  resources point into store paths nothing roots; Nix cannot predict the name;
  and a second run with the same package still restarted the daemon.
- **Activation stops the daemon and never restarts it.** Restarting on change is
  the obvious shape, and the one prior Home Manager implementation found in
  2026-09 does it. Here it would give the daemon home-manager's activation
  environment, and every later session would run its tools in it.
- **`daemon_auto_start = false` does not isolate devenv.** The TUI still
  attaches to a daemon that is already running (`startup_orchestration.rs`,
  `existing_daemon`). Only `--no-daemon` refuses it.
- **Do not size the stop from upstream's limits.** 2026-09-26, PR #1989: a 705s
  bound (upstream's 375s lock wait + 300s maximum grace) could never fire under
  the 5-minute activation unit, which killed activation first.
- **A daemon that survives a failed stop is stale, not broken.** Nix GC roots
  the whole store path of a running process's executable, so the old package,
  bundled bwrap included, lives until the daemon exits (measured 2026-09-26, Nix
  2.34.4, PR #1989 review).

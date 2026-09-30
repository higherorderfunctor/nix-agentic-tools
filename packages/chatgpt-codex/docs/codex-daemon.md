# Codex's app-server daemon: Home Manager selects its package

> **Last verified:** 2026-09-30 — the selector's worst case is bounded to fit
> Home Manager's activation unit, its owned shape comes from
> `lib/packageLayout.nix`, and its warn-and-continue paths are gated. The
> daemon's `settings.json` is a read-only copy of `native.daemonSettings`.
> `pinDaemonToPackage` is declared under `hm.options`, not the shared option
> set, so devenv genuinely has no such option rather than rejecting it by
> assertion; with `ai.codex.package = null` it stays silent at its default and
> warns only if set explicitly.

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
- **The opt-out.** `false` restores upstream's copy and updater. That copy has
  the same voice/zsh resources as `--from-cli` below, pointing into store paths
  nothing roots, so they break after GC until the updater replaces the copy.
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

## Gates

- `checks/chatgpt-codex-daemon-selection.nix` runs the rendered activation
  against the real daemon: pin, unchanged re-pin under a held lock, simulated
  bump, unpin, and a foreign `current` that survives, with the settings copy
  read-only at each step. A store-path `current` is outside upstream's
  documented layout, so a release that stops honoring it fails there, in its
  update PR. It then drives the warn paths with stub roots and a selector whose
  waits are shortened through `.override`: a stop that fails, one that hangs,
  and a lock held past the wait each exit 0 with a `warning:`.
- `--no-daemon` is listed in `extractedCoverage.nix` `cli.launcherFlags`, and
  chatgpt-codex-coverage fails, as launcher policy rather than a stale
  disposition, if upstream drops it.

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

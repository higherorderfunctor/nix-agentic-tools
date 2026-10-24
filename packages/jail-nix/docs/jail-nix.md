# jail.nix library

> **Last verified:** 2026-10-24 — Claude airlock uses a pre-bwrap runtime
> permission and descriptor-backed per-launch CA delivery. The input tracks a
> tested GitHub mirror through the dependency sweep; `ai-jail-live` proves on a
> CI runner that the launcher runs inside bubblewrap.

jail.nix (`sourcehut:~alexdavid/jail.nix`, read through the GitHub mirror
`higherorderfunctor/jail.nix`) is a pure Nix library that wraps a program in
bubblewrap. It is not a NixOS module, so Home Manager and devenv need no
polyfill: a jail is a package on `PATH`.

`lib.ai.jail` (`lib/jail.nix`) re-exports it, and modules receive the same value
as `ai.internal.jail`:

- `init pkgs` returns the builder `jail name exe permissions`.
- `extend {pkgs; additionalCombinators; basePermissions; bubblewrapPackage}`
  returns the same builder with those overrides.
- `combinators pkgs` is an `additionalCombinators` function adding `mask-path`,
  `unset-env`, `restore-path` and `strict-runtime` (`lib/combinators.nix`).
- `src` is the pinned source tree.

The builder yields a `writeShellApplication` that `exec`s bwrap. `exe` is a
package (its `meta.mainProgram`) or a string path. Both entry points take the
caller's `pkgs`, as `lib.ai.mkSandbox` does. There is no package leaf, so
nothing reaches cachix and no pin-parity check applies.

`src` is the source path, not the flake input. The owner library walker recurses
into every non-derivation attrset, and the flake input fails it with
`cannot coerce a set to a string`.

## Upstream defaults are an allow-list

The stock `basePermissions` are `base`, `bind-nix-store-runtime-closure` and
`fake-passwd`:

- `--tmpfs ~`, `--tmpfs /tmp`, a fresh `/proc` and `/dev`.
- `--clearenv`, then forward only `LANG`, `HOME` and `TERM`. The wrapper runs
  under nounset, so all three must be set, and `HOME` must be creatable:
  `fake-passwd` writes under `~/.local/share/jail.nix`.
- Bind only the runtime closure of `exe` from the store.

The finalizer unshares the user, ipc, pid, net, uts and cgroup namespaces and
adds `--new-session` and `--die-with-parent`. `share-ns`, `network`,
`no-new-session` and `no-die-with-parent` undo those. The result forwards only
`man`, `shellPath` and `override` from `exe`; `passthru` is dropped.

## The extend seam

`basePermissions` replaces what every jail starts from. A jail's own
`permissions` run after it; upstream's `reset` combinator can remove the base
contributions by restoring the initial state.

`additionalCombinators` receives the built-in combinators and returns raw
`state -> state` functions, not upstream's `{sig; doc; impl}` records. jail.nix
has no `--unsetenv` combinator; the repository's `unset-env` emits it.

## Pinning and bumps

The input is `github:higherorderfunctor/jail.nix/main`, a mirror of sourcehut,
and it moves through the 4x/day dependency sweep like any root input. The
mirror's default branch, `gh-mirror-meta`, holds only its README and
`mirror.yml`, so the URL names `main`. Upstream has no inputs, so there is no
`follows`.

`mirror.yml` runs two hours before each sweep. When an upstream branch or tag is
missing or different on the mirror, it pushes heads and tags with `--force` and
no pruning, never over `gh-mirror-meta`, and then runs upstream's own suite on
`main`. The push comes first, so a failing suite fails the run, not the mirror.

A bump is judged in three places:

- The sweep's `mirror-health` job fails when the newest completed mirror run
  whose `sync` job started did not succeed, or when no mirror run started in 8
  hours. It only reports: no job needs it, and the bump PR still opens.
- `ai-jail-live` (`checks/ai-jail/live.nix`), run by ci.yml's `jail-smoke` job,
  jails a probe with nothing excluded on the runner. Its fresh `/proc` must list
  only the jail's own processes, and the same probe outside must list the
  runner's. Upstream's suite on the mirror covers combinator behavior.
- The checks below and `checks.devenv-inputs-drift`, which compares `flake.nix`,
  `devenv.yaml` and `devenv.lock`.

There are no patches or `pkgs` pin. Add an `applyPatches` seam only when needed,
pointing `src`, `init` and `extend` at the patched tree.

## Checks

The structural pair lives in `checks/jail-nix.nix` under
`lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux`, so their names are absent
on Darwin.

- `jail-nix-trivial` renders a jail around coreutils' `true` and requires the
  bubblewrap store path and `-- <exe>` in the wrapper. The jail uses
  `share-ns "net"`. It runs only when an independent
  `bwrap --unshare-user --unshare-pid --ro-bind / / -- true` succeeds inside the
  build sandbox; neither probe unshares the network namespace. Structural
  assertions run unconditionally. The log and `$out` say which branch ran:
  `JAIL-NIX-TRIVIAL: executed …` or `JAIL-NIX-TRIVIAL: structural-only …`. A
  cached result prints neither; read `$out`.
- `jail-nix-extend` adds a `probe` combinator through `extend` and requires
  `--setenv JAIL_PROBE` in the rendered wrapper.

## `ai.jail` and `ai.<runtime>.jail`

The option library is `lib/ai/jail/default.nix`. Root `ai.jail` and
`ai.claude.jail`, `ai.codex.jail`, `ai.kimchi.jail` and `ai.kiro.cli.jail` share
one submodule, every field `null` by default: `enable`, `exclude.paths`
(absolute), `exclude.environment` (variable names) and `permissions` (a function
from the combinator set to a list). A non-null runtime field replaces the root
field, lists included; `ai.<runtime>.normalized.jail` holds the fold, null
unless it enables the jail. Nothing is jailed and nothing is excluded unless the
consumer sets it.

The install seam in `lib/ai/app/mkBackendTransform.nix` wraps the finished
launcher, outermost and in place: one jail per entry point in `executables`,
joined with `share/`, so `claude` is the jailed one and the factory wrapper runs
inside. Other `bin/` entries, such as `codex-code-mode-host`, pass through with
no jail of their own and run inside the jail that spawned them.

The profile replaces `basePermissions`: `--dev-bind / /`, a fresh `/proc` and a
minimal `/dev`, the environment kept, `share-ns "net"` for a loopback proxy,
`no-new-session` for the TUIs, `--chdir "$PWD"`, then the masks, caller-PATH
restoration, variable exclusions and `permissions`. Final permissions can
deliberately restore an excluded variable with `set-env`, including `PATH`.
Masks resolve through `realpath` at launch: a directory becomes a tmpfs, a file
an empty read-only file, a missing path is skipped.

For an airlock-selected Claude, an internal permission runs after the user's
permissions and before bwrap. It reads the rendered service config and client
file, checks the current CA and system roots, and adds one read-only
`--ro-bind-data` from an opened, unlinked private bundle. Pinned bubblewrap
0.12.0 supports that descriptor option. The wrapper unlinks the random private
pathname before populating the bundle through its descriptor. Temporary traps
remove the name if preparation is interrupted, then restore prior traps; an
existing `add-cleanup` handler also runs on preparation failure. Without
`add-cleanup`, the wrapper can `exec` bwrap, so signals, stdin and exit status
follow the normal process path without a cleanup supervisor. The offline check
makes its mock read the inherited descriptor and checks preparation and running
signals, stdin and status; it does not prove a live namespace mount.

On Darwin the option evaluates, installs the plain launcher, and both backends
warn:
`ai.<runtime>.jail is enabled but bubblewrap is Linux-only; nothing is jailed on <system>.`
Copilot ships no launcher and gets the delivery warning.

Known interactions, not solved here:

- Home Manager pins Codex's shared app-server daemon. A daemon started by a
  client outside the jail runs outside it, and a jailed client can attach to it;
  devenv's launcher passes `--no-daemon`.
- Kimchi's wrapper exports `KIMCHI_API_KEY` from its redact reference inside the
  jail, so masking that secret file breaks launch, and the real key still
  reaches the harness.
- Kiro's default FHS launcher selects its internal `/usr/bin/kiro-cli-chat`
  before inherited `PATH`. With FHS disabled, the PATH lookup can select the
  installed chat wrapper and add another `ai.jail`. Both routes remain inside
  the outer jail.

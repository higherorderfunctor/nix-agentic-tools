# kiro-cli: probing the binary

> **Last verified:** 2026-11-06 — probes run the unwrapped store binary in a
> scrubbed environment inside a network-less bubblewrap, and measured facts are
> recorded in `launcher-argv.md` and asserted by two checks that move together.

Measure the binary; do not assume its behavior from help text or from the
vendor's documentation. The recipe below keeps a probe from reaching the real
home directory, the login or the network.

## Scrub the environment, not just `HOME`

A scratch `HOME` alone is not enough: Kiro finds its data directory, and the
user's login with it, through `XDG_DATA_HOME` and the other `XDG_*` variables.
`env -i` drops all of them. Run the unwrapped binary (a `PATH` lookup finds the
wrapper, which is the thing under test), inside `bwrap` so the real home and the
network are out of reach:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

kb=$1 # path to the unwrapped kiro-cli
shift
h=$(mktemp -d)
bwrap --dev-bind / / --tmpfs "$HOME" --bind "$h" "$h" --tmpfs /run/user \
  --unshare-net \
  env -i HOME="$h" PATH=/usr/bin:/bin TERM=dumb XDG_RUNTIME_DIR="$h/run" \
  KIRO_NO_AUTO_UPDATE=1 KIRO_DISABLE_TELEMETRY=1 \
  timeout 10 "$kb" "$@" </dev/null
```

Save it as `probe` and call it with the binary and the arguments under test, for
example `probe "$KB" --v3 chat --wrap=foo --help`.

## Rules

- **Never start a session or log in.** A `--help` placed after `--` becomes chat
  input and starts the KAS agent runtime. Put `--help` last and before any `--`.
- **Print the whole table first.** Run the full set of probes once, showing each
  argument list, exit code and first output line, before adding or changing any
  assertion.

## Where measured facts live

Facts live in `launcher-argv.md` and are checked by `kiro-kas-dispatch`
(`packages/kiro-cli/checks/kas-dispatch.py`) and `kiro-wrapper-argv`
(`packages/kiro-cli/checks/kiro-wrapper-argv.nix`). A re-measure that changes a
fact updates the document and both checks in the same commit. The re-measure
recipe for a version bump is in the "Re-measuring on a version bump" section of
`launcher-argv.md`.

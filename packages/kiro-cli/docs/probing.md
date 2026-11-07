# kiro-cli: probing the binary

> **Last verified:** 2026-11-07 — five probe classes; all but usage calibration
> run the pinned unwrapped binary scrubbed and offline without asking.

**Pick the lowest class that answers the question.**

Measure the binary; do not assume its behavior from help text or from the
vendor's documentation. Never use the operator's login or reach the real Kiro
service; anything offline, with a fake or fixture key, inside the sandboxes
described here, runs without asking.

## The `probe` launcher

A scratch `HOME` alone is not enough: Kiro finds its data directory, and the
user's login with it, through `XDG_DATA_HOME` and the other `XDG_*` variables.
`env -i` drops all of them. Run the unwrapped binary (a `PATH` lookup finds the
wrapper, which is the thing under test), inside `bwrap` so the real home and the
network are out of reach. `PROBE_CLASS` picks the class below:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

kb=$1 # path to the unwrapped kiro-cli
shift
class=${PROBE_CLASS:-flag} # flag, dispatch or engine
h=$(mktemp -d)
path=/usr/bin:/bin limit=10 extra=()
if [[ $class != flag ]]; then
  path="$(dirname "$kb"):$path" limit=30
  extra=(KIRO_API_KEY=offline-dispatch-fixture)
fi
if [[ $class == dispatch ]]; then # a stub node records KAS's argv and exits
  mkdir "$h/tmp"
  cat >"$h/node" <<STUB
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
printf '%s\n' "\$@" >"$h/capture.argv"
STUB
  chmod +x "$h/node"
  extra+=(KIRO_KAS_NODE_PATH="$h/node" KIRO_LOG_LEVEL=info TMPDIR="$h/tmp")
fi
rc=0
bwrap --dev-bind / / --tmpfs "$HOME" --bind "$h" "$h" --tmpfs /run/user \
  --unshare-net \
  env -i HOME="$h" PATH="$path" TERM=dumb XDG_RUNTIME_DIR="$h/run" \
  KIRO_NO_AUTO_UPDATE=1 KIRO_DISABLE_TELEMETRY=1 "${extra[@]}" \
  timeout "$limit" "$kb" "$@" </dev/null || rc=$?
if [[ $class == dispatch ]]; then
  if [[ -e $h/capture.argv ]]; then echo "KAS spawned:"; cat "$h/capture.argv"
  else echo "KAS not spawned"; fi
  grep -hs "acp engine\|ACP initialize\|agentEngine" "$h"/tmp/kiro-log/*.log || :
fi
exit "$rc"
```

Save it as `probe` and call it with the binary and the arguments under test, for
example `probe "$KB" --v3 chat --wrap=foo --help`.

## 1. Flag and version facts

A flag probe's argument list ends in `--help` or `--version`, placed before any
`--`, and nothing sets `KIRO_API_KEY`. Run it as plain `probe`: fixed
`PATH=/usr/bin:/bin`, `timeout 10`, no credentials.

## 2. Dispatch and engine-selection facts

Which engine a launch selects, and whether it spawns KAS, are measured with
`PROBE_CLASS=dispatch probe`, the method of
`packages/kiro-cli/checks/kas-dispatch.py` (`capture_node`, `offline_env`,
`raw`): a `node` stub in the scratch directory, named by `KIRO_KAS_NODE_PATH`,
records its argv and exits; the binary's bin directory leads `PATH`; the check's
fixture key and `timeout 30` apply. It reports whether the stub ran, its argv
and any `acp engine` lines under `$TMPDIR/kiro-log/`. The server never starts.
The check's `smoke.request` supplies an ACP `initialize` when a client name
matters.

On 3.0.0, `PROBE_CLASS=dispatch probe "$KB" acp --agent-engine v3` spawned the
stub after about 10 to 16 s with `--experimental-wasm-modules`, the
`kiro-cli-kas` package's `acp-server.js`, `--transport=stdio` and
`--auth=acp-callback`, then exited 0; it logged no `kiro-log` lines. With
`--agent x` or `-a` added it exits 2 and spawns no stub. Without credentials,
`--agent x`, `--model auto`, `--effort low`, `--trust-tools=x` and `-a` each
exit 2 with
`error: the following arguments are not supported with --agent-engine=v3: <opt>`
(`-a` reports `--trust-all-tools`).

## 3. Prompt, steering and payload facts

Any question about what the engine sends goes to the offline replay harness,
[`packages/delegate-routing/probes/delegates/kiro/README.md`](../../delegate-routing/probes/delegates/kiro/README.md).
`wire2.sh` runs the pinned unwrapped binary in a loopback-only network
namespace; `fixture_home.py` seeds a scratch `HOME` with a fake builder-id token
and points all four service endpoints at `capserver2.py` on `127.0.0.1:18765`,
which records every request in `run/wire.jsonl`; `reach.py` reads prompt offsets
and markers from it. Cases `w-v3`, `k3-dup` and the `pr-*` set are the models.
It starts the real engine but uses no login and no network.

## 4. Usage calibration

[`packages/kiro-cli/usage/README.md`](../usage/README.md): the harness records
real traffic through a proxy on the operator's account and login, so it is the
one class that needs the operator: use it for usage calibration only, after the
operator approves each capture run.

## 5. Running the real engine outside a harness

Last resort, for a fact classes 1 to 4 cannot answer. An engine-start probe is
every probe not covered above, including any `chat`, `acp` or `serve` invocation
outside classes 2 and 3 and any invocation with `KIRO_API_KEY` set. Run it only
as `PROBE_CLASS=engine probe`: the fixture key, the binary's bin directory
prepended to `PATH`, `timeout 30`, inside the same offline `bwrap`. Report what
started: the exec chain, any listen or bind, and the files written under the
scratch `HOME`.

Measured on the pinned `kiro-cli 3.0.0` unwrapped binary, `env -i`, scratch
`HOME`, `PATH=/usr/bin:/bin`, `--unshare-net`, stdin `/dev/null`:

- Without credentials and with `timeout 10`, `acp --agent-engine v3` exits 0 in
  about 0.03 to 0.1 s at the login gate, printing `Not logged in.` and a pointer
  to `KIRO_API_KEY` or `kiro-cli login`. Under `strace -f` (execve, listen,
  bind) it shows only the binary, its wrapped self and `ldd --version`: no node
  or bun exec, no listen or bind, so no agent server starts.
- With `KIRO_API_KEY=offline-dispatch-fixture` and `timeout 30`, KAS starts (it
  execs node, binds sockets and logs `kas.server.starting`) after about 10 to 14
  s, and the process exits 0 after stdin's EOF. Under `timeout 10` the probe is
  killed (exit 124) before or as KAS starts. The 3.0.0 payload ships only
  `kiro-cli`, and the fixed `PATH` did not stop KAS from starting.

## Rules

- **Never log in.** A `--help` placed after `--` becomes chat input and starts
  the KAS agent runtime, which makes the probe an engine-start probe. Put
  `--help` last and before any `--`.
- **Print the whole table first.** Run the full set of probes once, showing each
  argument list, exit code and first output line, before adding or changing any
  assertion.

## Where measured facts live

Facts live in `launcher-argv.md`, checked by `kiro-kas-dispatch` and
`kiro-wrapper-argv`; a re-measure that changes a fact updates all three in one
commit. The version-bump recipe is in its "Re-measuring on a version bump".

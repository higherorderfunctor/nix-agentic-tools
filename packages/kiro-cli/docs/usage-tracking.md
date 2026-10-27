# Private Kiro usage tracking

`ai.kiro.cli.usageTracking` is an opt-in local TLS capture service and Kiro
launcher configuration. The shared `mkKiro` factory provides the same options on
Home Manager and devenv. Its SQLite database is independent of Airlock and
contains private request and response payloads.

```nix
ai.kiro = {
  cli = {
    enable = true;
    v3 = true;
    usageTracking = {
      enable = true;
      # Optional absolute directory. Null uses the runtime XDG state root.
      dataDirectory = null;
      maxPayloadBytes = 268435456;
      port = 18089;
    };
  };
};
```

By default state lives in
`${XDG_STATE_HOME:-$HOME/.local/state}/kiro-cli/usage`: `usage.sqlite3` and its
WAL files, plus the `ca` directory holding mitmproxy's private CA key and public
certificate. The service creates private directories with mode 0700 and refuses
an existing directory with another owner, mode, or a symlink in its place. Keep
this directory private and outside the repository. `dataDirectory` is a literal
absolute path, with no shell expansion. Service and launcher must resolve the
same runtime state directory.

The service runs the flake's pinned nixpkgs `mitmproxy` package, binds only
`127.0.0.1`, and claims its port through `ai.services`. It intercepts only
`runtime.us-east-1.kiro.dev:443`; the addon records `/v1/responses`. Other
destinations pass through without TLS interception. This initial host scope
follows the observed runtime endpoint and does not claim complete coverage of
every Kiro region or API. See [the collector notes](../usage/README.md) for
storage, decoding, omission counters, and offline replay details.

## Start and stop

On Linux Home Manager, enable the option in your personal configuration and
apply it with your ordinary Home Manager activation command (for example,
`home-manager switch`). The generated user service starts automatically with the
managed user service lifecycle. Then run `kiro-cli` normally: the Home Manager
launcher already tracks it. Use `systemctl --user status kiro-usage.service` to
diagnose readiness failures.

From a project that supplies its own Kiro through devenv, reuse that same Home
Manager collector:

```console
kiro-usage exec kiro-cli
kiro-usage exec kiro-cli chat "your prompt"
```

`exec` resolves the command through the current `PATH`, so the project's Kiro
remains selected. It uses the installed tool's configured port and state
directory; no `usageTracking` setting or proxy environment belongs in the
contributor project's configuration. Wrapping the already tracked Home Manager
launcher is also supported: the identical proxy and CA environment passes its
conflict checks. No second collector starts.

`exec` replaces itself with the selected command, preserving arguments, exit
status and signals. It sets proxy and Node CA variables and clears bypass
variables only for that invocation and its descendants, replacing conflicting
inherited values. Your shell environment stays unchanged. For commands named
`kiro-cli`, it prepends `--v3` unless already present; named Kiro commands
reject explicit non-v3 `--agent-engine` overrides before `--`. Direct
`kiro-cli-chat` needs explicit `--v3` or `--agent-engine v3`. Other command
names receive arguments unchanged; callers must ensure those programs use the
Node trust path. Use `kiro-usage exec -- COMMAND ...` when an explicit command
boundary is useful.

For a standalone devenv-managed collector, start `kiro-usage` through the
process supervisor with `devenv up kiro-usage`. Home Manager on Darwin emits the
existing `ai.services` warning because it has no systemd user service backend;
use devenv there for the managed service.

The service creates its CA on first start. A tracked launcher checks the private
directory, CA file, and local listening port before starting Kiro. Missing
readiness fails with an actionable error; it does not silently launch without
capture. The readiness probe connects only to the local port and sends no
provider request.

The launcher sets HTTP and HTTPS proxy variables in both cases and
`NODE_EXTRA_CA_CERTS` for its process and descendants. It clears `ALL_PROXY` and
`NO_PROXY` in both cases so inherited routing cannot bypass capture. Configured
conflicting proxy or Node CA environment entries fail evaluation; inherited
nonempty conflicts fail before launch. To use a shell that already exports proxy
variables, remove those variables for the tracked invocation. Node trusts this
extra CA only within the launched process tree. The module does not add a CA to
the operating system trust store. Tools spawned by Kiro inherit these
environment variables too; their own TLS implementations may have different
trust requirements.

A managed Kiro package and `cli.v3 = true` are required. Tracked launches reject
an explicit non-v3 `--agent-engine` override. Direct `kiro-cli-chat` launches
also require an explicit `--agent-engine v3` or `--v3`, because `cli.v3` injects
its flag only into `kiro-cli` and does not establish the chat binary's default
engine. This configures the v3 Node trust path; it does not verify every
upstream transport implementation. Local tests use fake Kiro and proxy
processes, and no live Kiro launch or provider request forms part of the check
suite.

Stopping the service while tracking remains enabled makes subsequent tracked
launches fail. Disable `usageTracking.enable`, apply the configuration, then use
the untracked launcher. Disabling creates no usage service, proxy variables, CA
trust, or query tool. Existing capture data is retained for explicit inspection
or deletion.

## Inspect a session

Enabling the option installs `kiro-usage` alongside the managed Kiro commands:

```console
kiro-usage index --sessions ~/.kiro/sessions
kiro-usage session sess_example
kiro-usage session sess_example --scope tree
kiro-usage list
kiro-usage replay CAPTURE_ID
```

Indexing is explicit. It reads only the sessions directory supplied to that
command and updates the same separate SQLite database. A session query reports
attributed requests and usage, with session-only or descendant-tree scope;
incomplete joins remain visible. It does not guess an attribution where the
captured protocol and local index do not establish one. Replay writes private
payloads to standard output, so choose its destination deliberately.

The default payload budget is 256 MiB of compressed payload bytes. Once full,
collection keeps accounting and exposes omitted-payload counters instead of
retaining new payloads. It does not delete old captures. This is a payload
budget, not a whole-directory quota: metadata, session indexes, SQLite pages,
and WAL files need additional space. Inspect storage and omission status before
relying on a capture as complete evidence.

## Run the calibration experiment

From a checkout, preview the paid experiment without calling Kiro:

```console
python3 packages/kiro-cli/usage/calibration.py
python3 packages/kiro-cli/usage/calibration.py --run
```

The explicit `--run` executes ten sequential non-interactive invocations using
`claude-opus-5.5` at low effort: repeated medium input, input and output size
variations, a three-turn conversation resumed by session ID, and a final repeat
after more than six quiet minutes. These are experiment labels; a cold cache is
not established. A unique run prefix reduces reuse from earlier experiments, but
global context remains uncontrolled. Compare captured request hashes offline
before interpreting cache differences. CLI invocation counts can differ from
provider request counts.

The script requires an existing collector database and checks complete retained
captures with credits and context usage after every invocation. Missing or
incomplete evidence stops the experiment without retrying paid calls.
`--db /absolute/path/usage.sqlite3` selects a non-default database for these
read-only checks; it must match the installed collector's state directory.
`--timeout 180` sets the per-command timeout. The script prints its private
temporary workspace and manifest path, retains bounded logs and prompt fixtures
outside the workspace, and records workspace changes. Keep those artifacts for
offline attribution. Its final session-index step is nonfatal and prints a
separate retry command if needed. Tests use fake executables and make no
provider calls.

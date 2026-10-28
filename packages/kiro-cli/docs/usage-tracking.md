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
`runtime.us-east-1.kiro.dev:443`; the addon records `/v1/responses` (root turns)
and `/generateAssistantResponse` (workflow steps and subagents). Other
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

After `kiro-usage exec kiro-cli` or `kiro-usage exec kiro-cli-chat` exits, the
tool prints model totals and a pooled credit/token summary to standard error.
Kiro inherits the terminal's input and output directly; the summary leaves
standard output, exit status, and signals intact. Tracked chat runs as a child
of the summary supervisor, with its own process ID and the same terminal
descriptors. Explicit help, version, login, and administrative commands skip the
summary, including when recognized global options precede them. Other commands
run without a Kiro summary.

A local proxy marker identifies captures from this invocation, and their
recorded conversation identities select the sessions to report. The tool does
not parse Kiro's screen or guess a session from its process ID. Reports contain
full root-linked session totals, including earlier work when you resume a
session and captured calls linked by explicit root conversation identity. Root
conversation contains calls whose conversation ID matches the selected root;
Other linked conversations have a different ID; Unknown has no recorded
conversation ID. These are conversation groups, not caller roles: workflow steps
and subagents carry their own conversation IDs and land in other linked
conversations, which can also include helpers or forks. Disk turn credits never
enter these captured-call totals. Requests, total/input/output/cached tokens,
request hit rate, and credits are grouped by model and pool, with no
per-delegate listing. Missing counters stay unavailable. For `claude-opus-5.5`
at low effort, retained complete text-only responses of 1–5 characters within
the calibrated context range can additionally show `Discount %`. This
experimental credit-price signal classified 8 of the initial 10 calls: 5
discount-like and 3 baseline (~62.5% discount-like, including partial discounts
rather than only fully discounted requests); the two longer outputs were
excluded. It is distinct from counter-derived `Hit %` and does not estimate
input, output, or cached tokens. Coverage, anomalies, and exclusions remain
visible; unsupported cases stay unavailable. The compared initial calls retained
identical delivered hooks/context, but this small run establishes neither
percentile accuracy nor a transferable cache-hit model. Exact counters always
win per call; a `~` cell adds estimates for calls that lack the exact counter,
with (known/all) coverage. A call with a reported context percentage and a model
with a known window (`claude-opus-5.5`: 1,000,000 tokens) estimates total tokens
as that share of the window, output as one token per four output characters
(text, tool-call arguments, and reasoning from retained events, or the terminal
response when it streamed no deltas of that kind), and input as the difference.
Only models with fitted credit rates (`claude-opus-5.5`) and reported credits
and a known or estimated output also estimate cached tokens, from the full-miss
and full-hit curves below, clamped to the estimated input. Other calls stay
unavailable. Hit percentage is the share of requests with cached tokens among
requests with a cached value; an estimated split counts as a hit only at 1% of
input or more, with partial coverage shown. If no captured conversation identity
is available, the tool reports that the summary is unavailable. On exit the tool
first waits up to two seconds for the asynchronous capture writer to persist and
finish this launch's calls, since the disk scan below is scoped by them;
unfinished calls remain flagged as incomplete coverage and the disk observations
as not refreshed. It then automatically refreshes the local disk index from
`~/.kiro/sessions` when that directory exists. This exit scan reads the
`session.json` of sessions changed since the launch, indexes the messages only
of those linked to captures, and never prunes. Index failures warn and leave the
child exit status intact; disk observations may then be stale. An explicit
`kiro-usage index` holds a lock beside the database for its whole pass; the exit
scan then skips with a one-line warning instead of interleaving, and reports
disk observations as not refreshed. Exit scans of concurrent launches do not
skip each other; they queue on a second lock and run one at a time, since two
scans of one session would index the same records. Rerun the index if that pass
began before Kiro exited. Nested `kiro-usage exec` launches share the parent's
marker and produce one summary when the outer launch exits.

`exec` preserves arguments. It sets proxy and Node CA variables and clears
bypass variables only for that invocation and its descendants, replacing
conflicting inherited values. Your shell environment stays unchanged. For
commands named `kiro-cli`, it prepends `--v3` unless already present; named Kiro
commands reject explicit non-v3 `--agent-engine` overrides before `--`. Direct
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
kiro-usage session sess_example --json
kiro-usage list
kiro-usage replay CAPTURE_ID
```

Session and list queries print plain text tables by default. Session reports
show captured calls by requested model, counter coverage, and separate disk
observations. An em dash means unknown or unobserved; zero means an observed
zero. Disk turn credits overlap captured credits and must never be added.
Warnings go to standard error.

Scripts that previously parsed session JSON or list JSON lines must now pass
`--json`: `kiro-usage session sess_example --json` preserves the full report,
and `kiro-usage list --json` preserves one full JSON object per capture.
`kiro-usage index --sessions DIR --json` returns index counts. Replay continues
to write original response bytes; it has no table or JSON mode.

Tracked `exec` launches refresh the default local session tree automatically; no
separate index command is needed for that workflow. Use the explicit
`index --sessions DIR` command for another tree, to refresh without launching
Kiro, or to pick up sessions changed outside a tracked launch. Both paths update
the same separate SQLite database. Session queries use the last completed index
without refreshing it. A session query reports attributed requests and usage,
with session-only or descendant-tree scope; incomplete joins remain visible. It
does not guess an attribution where the captured protocol and local index do not
establish one. Replay writes private payloads to standard output, so choose its
destination deliberately.

The index covers only sessions linked to captures: a session whose ID is a
captured conversation or root conversation ID, or whose `session.json` names an
indexed session through `rootConversationId`, `parentSessionId`,
`rootSessionId`, or `_meta.kiro.serverSession.ownerSessionId`. Workflow steps
reach their root this way, and tree queries follow the same links. Unlinked
sessions whose files all predate the earliest capture are skipped without
reading; Kiro rewrites `session.json` when a session resumes. Children written
before tracking began are therefore not indexed. The explicit command prunes
disk rows for sessions no longer in scope and then runs `VACUUM`, so the file
shrinks. `VACUUM` holds the write lock while it rewrites the file, so a running
collector waits on its busy timeout meanwhile; after pruning this takes well
under a second, but run it between Kiro sessions on a large capture store. A
second explicit index waits for a running one; a tracked launch's exit scan
skips while it runs.

Malformed or unreadable session metadata does not stop other sessions from
indexing. Its omission is recorded, stale metadata is retired, and a successful
re-index after repair clears the omission. Reports show global session metadata
omissions because unknown ancestry may hide descendants. Index summaries count
both record and session metadata omissions.

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

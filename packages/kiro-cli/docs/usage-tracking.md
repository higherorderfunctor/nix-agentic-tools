<!-- cspell:words rrggbb -->

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
      payloadWarnBytes = 1073741824;
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
and the GenerateAssistantResponse AWS JSON RPC call (workflow steps, subagents
and titles): path `/` whose `x-amz-target` is exactly
`KiroRuntimeService.GenerateAssistantResponse`. Other operations on `/` pass
through uncaptured; other destinations pass through without TLS interception.
This initial host scope follows the observed runtime endpoint and does not claim
complete coverage of every Kiro region or API. See
[the collector notes](../usage/README.md) for storage, decoding, omission
counters, and offline unpack details.

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
tool prints what that run captured to standard error: for each root session the
run touched, model and conversation tables (requests, credits, input, output and
cached tokens, cache hit). Kiro inherits the terminal's input and output
directly; the summary leaves standard output, exit status, and signals intact.
Tracked chat runs as a child of the summary supervisor, with its own process ID
and the same terminal descriptors. Explicit help, version, login, and
administrative commands skip the summary, including when recognized global
options precede them. Other commands run without a Kiro summary.

`usageTracking.summary` styles that summary. Null options keep the runtime
defaults (`color = "auto"`: styled only on a terminal without `NO_COLOR`;
`border = "none"`; `icons = false`), and only set options reach the theme file
the tool passes as `--summary-theme`:

```nix
ai.kiro.cli.usageTracking.summary = {
  border = "rounded"; # ascii, double, heavy, none, rounded or single
  color = "always"; # always, auto or never
  icons = true; # Nerd Font glyphs before the headline and caveat
  styles.total = "bold #ffaf00"; # per element: attributes, palette colors, #rrggbb, on-<color>
};
```

[The collector notes](../usage/README.md) list the style elements, their
defaults and the spec grammar.

A local proxy marker identifies captures from this invocation, and their
recorded conversation identities select the sessions to report. The tool does
not parse Kiro's screen or guess a session from its process ID. Switching or
forking a session with `/chat` inside one run touches several root sessions, so
no single session view describes a run: the summary prints one block per root
session, each counting only this run's captured calls whose root conversation
ID, or else own conversation ID, names that root. Earlier runs of a resumed
session, other runs and calls matched only through the disk index stay out. For
a whole session, earlier runs included, run `kiro-usage report --session ID`,
repeated for each root. Root conversation contains calls whose conversation ID
matches the selected root; Other linked conversations have a different ID;
Unknown has no recorded conversation ID. These are conversation groups, not
caller roles: workflow steps and subagents carry their own conversation IDs and
land in other linked conversations, which can also include helpers or forks.
Disk turn credits never enter these captured-call totals. Requests,
total/input/output/cached tokens, cache-hit token share, and credits are grouped
by model and pool, with no per-delegate listing. Missing counters stay
unavailable. For `claude-opus-5.5` at low effort, retained complete text-only
responses of 1–5 characters within the calibrated context range can additionally
show `Discount %`. This experimental credit-price signal classified 8 of the
initial 10 calls: 5 discount-like and 3 baseline (~62.5% discount-like,
including partial discounts rather than only fully discounted requests); the two
longer outputs were excluded. It is distinct from counter-derived `Hit %` and
does not estimate input, output, or cached tokens. Coverage, anomalies, and
exclusions remain visible; unsupported cases stay unavailable. The compared
initial calls retained identical delivered hooks/context, but this small run
establishes neither percentile accuracy nor a transferable cache-hit model.
Exact counters always win per call; a `~` cell adds estimates for calls that
lack the exact counter, with (known/all) coverage. Estimates need a reported
context percentage and a model with a known window; cached tokens also need
reported credits and the model's fitted rates in `usage/rates.json`. Other calls
stay unavailable; [Token estimates](../usage/README.md#token-estimates) has the
formulas. Cache hit is the share of input tokens that were cached, cached ÷
input over the requests with both (exact, or estimated where the call lacks the
counter), with partial coverage shown. Estimated Cached and Cache hit cells
carry `±N%`: the estimated cached tokens' standard error as a whole-percent
share of the cell, omitted below 1% or when a model lacks a fitted credit error.
A run with no captured calls, such as a session resumed and exited without a
turn, prints one line saying so that points to `kiro-usage report --session ID`.
If this run's calls carry no conversation identity, the tool reports that the
summary is unavailable. On exit the tool first waits up to two seconds for this
launch's captured calls to finish and stay unchanged for 0.1 s, since the disk
scan below is scoped by them. The quiet period is a heuristic: a call started
just before Kiro exits can still land later. After a timed-out wait, unfinished
calls stay flagged as incomplete coverage. It then automatically refreshes the
local disk index from `~/.kiro/sessions` when that directory exists. The summary
reads no disk data; the refresh keeps `kiro-usage session` and
`report --session`, which do, current. This exit scan reads the `session.json`
of sessions changed since the launch, indexes the messages only of those linked
to captures, and never prunes. Index failures warn and leave the child exit
status intact; disk observations may then be stale. An explicit
`kiro-usage index` holds a lock beside the database for its whole pass; the exit
scan then skips with a one-line warning that disk observations were not
refreshed instead of interleaving. Exit scans of concurrent launches do not skip
each other; they queue on a second lock and run one at a time, since two scans
of one session would index the same records. Rerun the index if that pass began
before Kiro exited. Nested `kiro-usage exec` launches share the parent's marker
and produce one summary when the outer launch exits.

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
kiro-usage report
kiro-usage report --since 2026-10-01 --until 2026-10-31
kiro-usage report --session sess_example --session sess_fork
kiro-usage list
kiro-usage unpack CAPTURE_ID transport
```

Session and list queries print plain text tables by default. Session reports
show captured calls by requested model, counter coverage, and separate disk
observations. An em dash means unknown or unobserved; zero means an observed
zero. Disk turn credits overlap captured credits and must never be added.
Warnings go to standard error.

`report` prints every capture in the store, attributed to a session or not, in
the exit summary's style: a table by day and a table by model, each with a Total
row, recomputing every ~estimate per call from the current `rates.json` and
`models.json`. Days are local calendar days in the time zone `--help` names;
`--since` and `--until` take `YYYY-MM-DD` and include both ends. `--session ID`
shows that session's whole tree, every run included, in the exit summary's style
instead, limited to the same days when they are given; repeat it for each root a
session switch or fork left. A last line names the calculator: the fit dates in
`rates.json`, then the reported models with no rates entry or no context window,
when there are any. `--json` writes the structured report instead.

Scripts that previously parsed session JSON or list JSON lines must now pass
`--json`: `kiro-usage session sess_example --json` preserves the full report,
and `kiro-usage list --json` preserves one full JSON object per capture.
`kiro-usage index --sessions DIR --json` returns index counts. `unpack` writes
original request or response bytes (`request`, `transport` or `decoded`), or
JSON lines for its `chunks` and `events` modes; it has no table mode.

Tracked `exec` launches refresh the default local session tree automatically; no
separate index command is needed for that workflow. Use the explicit
`index --sessions DIR` command for another tree, to refresh without launching
Kiro, or to pick up sessions changed outside a tracked launch. Both paths update
the same separate SQLite database. Session queries use the last completed index
without refreshing it. A session query reports attributed requests and usage,
with session-only or descendant-tree scope; incomplete joins remain visible. It
does not guess an attribution where the captured protocol and local index do not
establish one. `unpack` writes private payloads to standard output, so choose
its destination deliberately.

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

Payloads are always retained. `payloadWarnBytes` (default 1 GiB of compressed
payload bytes) is a warning, not a cap: past it the collector logs one warning
line to its service journal and keeps capturing, and every tracked `exec` exit
summary prints a one-line warning with the store's size while it stays above.
Capture never deletes old captures. To retire a store, stop the `kiro-usage`
service, then archive or delete `usage.sqlite3` with its `-wal` and `-shm`
files; the next start creates a new one. The threshold counts payloads only:
metadata, session indexes, SQLite pages, and WAL files need additional space.

The collector parses every response byte as it arrives, so credits, context,
token counters, output character counts, and completion survive when it has to
skip storing a payload copy; such calls carry `request_payload_omitted` or
`response_payload_omitted` and cannot be unpacked in full. Its write queue holds
up to 40 MiB: one request at the 32 MiB API limit plus 8 MiB of streaming
headroom. Parsing runs in the proxy's response callback, so a large or densely
structured chunk delays that chunk's delivery while it is decoded; only the
database write is deferred. Most commits skip fsync, though the occasional one
that triggers a WAL checkpoint waits for the disk. A power loss or OS crash can
drop the most recent captures, but it cannot corrupt the database.

## Run the calibration experiment

From a checkout, preview the paid experiment without calling Kiro, then run it:

```console
python3 packages/kiro-cli/usage/calibration.py probe --models claude-sonnet-4.5,claude-haiku-4.5
python3 packages/kiro-cli/usage/calibration.py probe --models claude-sonnet-4.5,claude-haiku-4.5 --run
```

`--models` takes ids from `usage/models.json` (default `claude-opus-5.5`);
routers and unlisted ids are refused. `--run` makes ten sequential
non-interactive calls per model at low effort: a medium prompt and its warm
repeat, a short and a long prompt, a short and a long reply, a three-turn
conversation resumed by session ID, and a final repeat after more than six quiet
minutes. Models interleave within each step, so every warm repeat follows its
own cold call and the quiet wait is paid once. A model whose first call exits
non-zero, such as one refusing `--effort low`, is recorded under
`dropped_models` and the others continue. `probe --sweep` adds nine cold prose
calls of 500 to 16000 words before the final repeat; 24000 words exceeded
Linux's 128 KiB limit on one argument.

Each prompt family has its own agent file whose prompt starts with the user
prompt's nonce, because the agent prompt leads every request: with one shared
agent small calls hit its cached prefix, and with one shared output family
`claude-haiku-5.5`'s long reply hit the prefix the short one had just written
(0.0041 against 0.0067 credits). The labels are not verified cache states and
global context remains uncontrolled; compare captured request hashes offline
before interpreting cache differences. CLI invocation counts can differ from
provider request counts.

The script requires an existing collector database and checks complete retained
captures with credits and context usage after every invocation. Missing or
incomplete evidence stops the experiment without retrying paid calls.
`probe --db /absolute/path/usage.sqlite3` selects a non-default database for
these read-only checks; it must match the installed collector's state directory.
`--timeout 180` sets the per-command timeout. The script prints its private
temporary workspace and manifest path, retains bounded logs and prompt fixtures
outside the workspace, and records workspace changes and the `kiro-cli` version.
Keep those artifacts for offline attribution. Its final session-index step is
nonfatal and prints a separate retry command if needed. Tests use fake
executables and make no provider calls.

Fit the runs' rates, reading their captures read-only:

```console
python3 packages/kiro-cli/usage/calibration.py fit MANIFEST...
python3 packages/kiro-cli/usage/calibration.py fit MANIFEST... --write
```

`fit` pools each model's calls across the manifests into its fixed cost per call
and its miss, hit and output credits per token. A model needs three cold calls
(`medium_cold`, `size_short`, `size_long`, or the `probe --sweep` calls alone
once the pool has three) at two input sizes or more, an output pair whose long
reply bills more than its short one, and a `medium_warm` repeat billed below 80%
of its cold call. Without them, or when a cold call is more than 5% of its
credits off the fitted line, the model is refused and never written. The table
shows each rate's ratio to `claude-opus-5.5`'s, scaled by the rate-multiplier
share. `--write` replaces each accepted model's whole `usage/rates.json` entry,
with provenance naming the manifests; nothing else writes that file. `--db`
works as for `probe`. Refresh `usage/models.json` from the free model listing
with `python3 packages/kiro-cli/usage/calibration.py models`.

A pooled `validate` manifest adds its warm pairs to the hits and its cold calls
to the recorded residual without refusing on them, and its prose replies fit
`chars_per_token`, which the entry carries so estimates read output at the ratio
its rates were fitted at. Hits at two sizes, such as its small and large
holdouts, also solve for `unbilled_tokens`, tokens context % counts and the
model does not bill; a count below 0 or above the smallest call's input refuses
the model, and one under 1% of it counts as none. Each entry also carries
`credit_error`, the RMS share of credits the fit misses its cold, holdout cold
and hit calls by, which sets the `±` on estimated cached tokens; past 2% no
`chars_per_token` is fitted, since credits then cannot price one reply.

Check the rates on calls the fit never used:

```console
python3 packages/kiro-cli/usage/calibration.py validate --models claude-opus-5.5,claude-haiku-4.5
python3 packages/kiro-cli/usage/calibration.py validate --models claude-opus-5.5,claude-haiku-4.5 --run
python3 packages/kiro-cli/usage/calibration.py validate MANIFEST
```

`--run` makes five calls per model with the probe's safeguards, on prose unlike
the probe's: a ~2,000-word prompt and its exact repeat, the same pair at ~9,000
words, and a request for about 150 words of prose. It then evaluates itself;
`validate MANIFEST` repeats that offline and never writes. Each call is priced
at its designed cache state (nothing cached cold, all input warm) and PASSes
within the larger of 2% of its credits and 0.0005 credits; any FAIL or missing
call, or a requested model without rates, exits non-zero. A flat hit share of
the cold credits would leave both of `claude-opus-5.5`'s warm calls about
−0.00046 credits off, inside that floor, so read the two warm residuals, not
only their status. Pool a validate manifest into `fit` to fit `chars_per_token`
and `K`; it is then in-sample.

Findings of 2026-10-29 (`kiro-cli` 2.35.2, low effort):

- Hits billed 10–53% of their cold calls and `claude-haiku-5.5`'s expired
  `medium_delayed` 97%. `claude-sonnet-5.5` bills exactly its multiplier share
  of `claude-opus-5.5`'s rates in `usage/rates.json`. The 200k-window
  `claude-sonnet-4.5` and `claude-haiku-4.5` scale with their multipliers for
  hit and output tokens but bill misses at 0.51 of that. Their probe predates
  per-family agents: its `size_short` rode a shared prefix 6.5% below the line
  on the 1M models. `usage/rates.json` is regenerated with
  `calibration.py fit MANIFEST... --write` over the probe, sweep and validate
  manifests, and each entry's provenance names the manifests it came from.
- Out of sample, the first validate run passed every designed call within 0.4%.
  Its prose replies read 3.00, 2.97 and 4.64 characters per token on
  `claude-opus-5.5`, `claude-sonnet-5.5` and `claude-haiku-4.5`, where chars/4
  had missed by +10%, +10% and −6.5%; `claude-sonnet-4.5` refused the prose
  fixture (`content_filtered`) and reads chars/4.
- The four other models' `medium_delayed` repeats billed exactly their cold
  credits, consistent with the cache expiring within six quiet minutes. In
  interactive sessions every full miss followed at least 222 seconds idle,
  consistent with a ~5 minute TTL.
- `claude-haiku-5.5` is fitted from three probes, two sweeps and three validate
  runs. Its probe alone is refused: `medium_cold` billed 12–14% above the
  sweep's line, as did one `holdout_small_cold`, for an unknown cause that is
  not the fixture text. Its context % counts about 2548 tokens it does not bill,
  and its warm calls scatter from −54% to +27% of their price, so its
  `credit_error` is 0.105 and it reads chars/4.
- Resumed turns are no holdout: `kiro-cli chat --resume` strips the trailing
  `<EnvironmentContext>` block from earlier user messages, so the turn bills a
  full miss. Interactive sessions keep history byte-identical (105 of 106
  requests).

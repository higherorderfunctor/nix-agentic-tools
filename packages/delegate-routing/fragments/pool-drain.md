Before the first delegate, invoke the absolute `delegate-routing-plan` command
rendered in this runtime's skill with the requested roles and caller-observed
`--launch-context`. Use its decision as canonical; do not reproduce Reader
discovery or pace arithmetic manually. The helper must run the Reader of every
pool in the Pools table, including pools outside this runtime's launch targets;
the Reader column names the command, not a separate registration per target
runtime.

The helper ranks fitting measured candidates by worst-window pace, using each
window's reported length; a monthly pool is paced against its month, not the
week. Pool pace and buffer use unscoped windows only. Malformed windows drop
only their pace and warn with the pool/window name. Valid remaining shares
survive bad pace; an unreadable unscoped share makes the buffer unknown. The
minimum valid share of zero proves exhaustion even with bad pace or another
unreadable share: buffer and pace are zero and the pool remains measured.
Otherwise at least one usable unscoped window is required; readable shares
survive even when the pool remains unmeasured. A scoped window
`<window>:<model>` matches an exact configured family name in that pool and
limits only that family's candidates: their effective pace is the worse of the
pool pace and scoped paces, and 0% excludes only that family. A consistent idle
window (0% used, 100% remaining), scoped or unscoped, adds no limit regardless
of its reset value; other unscoped windows determine pool pace and buffer. An
all-idle pool has full buffer and pace 1.0 as a finite full-window baseline;
malformed scoped windows warn and refuse only their named family without failing
the pool. Unknown scopes warn with the window name without failing the pool.
Retry non-zero Reader exits and timeouts once after two seconds, sharing that
retry across identical commands; do not retry zero-exit invalid JSON or
envelopes. Execution failures, repeated timeouts or non-zero exits, invalid
JSON, invalid envelopes and ambiguous accounts make their registered pools
unreachable for this invocation; they never supply fit-only routes. A Reader
failure does not establish inference endpoint availability. Report each failed
shared command's registration group once per snapshot with a safe reason, never
Reader stderr, command text or exception payloads. JSON includes all warnings;
stderr includes failure warnings and the fallback notice; advisory notes stay
JSON-only. Every failed-Reader or dropped-window WARNING ends in "Report this
failure to the user." Missing registered commands, unbound routes and valid
envelopes without usable unscoped windows remain budget-unmeasured; an empty
valid window map is unmeasured. Apply exhaustion, scoped refusals and session
buffer exclusions before measured preference and session pace comparison. Apply
measured preference within each avoid partition. With no selectable measured
candidate, use fit alone and report budget/session uncertainty. If no reachable
choice survives, retain exclusions and report a loop failure with empty
candidates and a non-zero exit. Never treat exhaustion as unmeasured.

The configured session pool drains last: select a candidate only when every
other fitting measured pool is behind or level in pace (comparing effective
candidate paces) and its minimum remaining share across applicable windows is
strictly more than a fifth; only unscoped windows apply to this buffer. That
fifth is the buffer for the person using the session; unknown session identity
cannot certify it. A session pool with unmeasured pace or a null buffer is
excluded because its buffer cannot be certified. Aim for every pool to reach its
reset near empty. Do not report pool numbers unless asked.

Tier and pace do not establish role fit, trial eligibility, live availability or
cross-maker independence. Supply taskSummary, nullable proposerFamily,
nonInteractive, compact role requests and observed techniques in the launch
context; honor exclusions. Several observed models for one family are fine: the
helper launches the highest version. A refused request exits 2 with every
problem as `{"path", "message"}` records in a stdout `invalid-request` document
and runs no Reader or picker; fix the named paths, and report a `manifest.` path
to the user as a configuration fault. The helper judges hard-eligible families
with its tool-free one-shot picker before pool ranking. Missing/null proposer
identity or no usable picker emits the model-picker-unavailable warning (it may
end with ` Unavailable: <reason>.` per entry the helper could not build); report
it to the user and use the returned tier/pool fallback. For finder, first-check,
second-check and judge, never step down a tier. Try the shared avoided-family
fallback before reporting a loop failure when no qualified strong/frontier route
remains. Each role accepts unordered `avoid` and `exclude` lists of exact
configured family names, empty by default. Exclude removes routes with reason
"excluded by caller" and wins overlap; avoid never removes a route by itself.
Eligible non-avoided candidates precede eligible avoided candidates; measured
preference applies within each partition. Session pace still compares all
otherwise fitting measured candidates, including avoided ones. Retained avoided
alternatives carry fallback metadata; warn once per role only when its first
candidate is a fallback, naming its family and launch effort and asking the
caller to report the notice to the user. Preserve every trial, mode, tier and
session gate. The helper may run its configured tool-free picker even in
nonInteractive contexts; it launches no worker delegates; canonical launch lines
are routing specifications for the orchestrator to bind to native tools or named
launchers.

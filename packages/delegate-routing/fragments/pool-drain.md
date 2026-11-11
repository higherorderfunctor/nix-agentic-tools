Before the first delegate, invoke the absolute `delegate-routing-plan` command
rendered in this runtime's skill with the requested roles and caller-observed
`--launch-context`. Use its decision as canonical; do not reproduce Reader
discovery or pace arithmetic manually. The helper must run the Reader of every
registered pool, including pools outside this runtime's launch targets; a pool's
registered command is run once, with no separate registration per target
runtime.

The helper measures worst-window pace using each window's reported length; a
monthly pool is paced against its month, not the week. Pool pace and buffer use
unscoped windows only. Malformed windows drop only their pace and warn with the
pool/window name. Valid remaining shares survive bad pace; an unreadable
unscoped share makes the buffer unknown. The minimum valid share of zero proves
exhaustion even with bad pace or another unreadable share: buffer and pace are
zero and the pool remains measured. Otherwise at least one usable unscoped
window is required; readable shares survive even when the pool remains
unmeasured. A scoped window `<window>:<model>` matches an exact family name
configured for any runtime and limits only that family's candidates in that
pool: their effective pace is the worse of the pool pace and scoped paces, and
0% excludes only that family. A consistent idle window (0% used, 100%
remaining), scoped or unscoped, adds no limit regardless of its reset value;
other unscoped windows determine pool pace and buffer. An all-idle pool has full
buffer and pace 1.0 as a finite full-window baseline; malformed scoped windows
warn and refuse only their named family without failing the pool. Unknown scopes
warn with the window name without failing the pool. Retry non-zero Reader exits
and timeouts once after two seconds, sharing that retry across identical
commands; do not retry zero-exit invalid JSON or envelopes. Execution failures,
repeated timeouts or non-zero exits, invalid JSON, invalid envelopes and
ambiguous accounts make their registered pools unreachable for this invocation;
they never supply fit-only routes. A Reader failure does not establish inference
endpoint availability. Report each failed shared command's registration group
once per snapshot with a safe reason, never Reader stderr, command text or
exception payloads. JSON includes all warnings; stderr includes failure warnings
and the picker warning; advisory notes stay JSON-only. Every failed-Reader or
dropped-window WARNING ends in "Report this failure to the user." Missing
registered commands, unbound routes and valid envelopes without usable unscoped
windows remain budget-unmeasured; an empty valid window map is unmeasured. Never
treat exhaustion as unmeasured.

Checking roles name the output's `producers`, each with its model line
(`family`) and actual launch `effort`. Exclude accepts configured model-line or
maker names and removes every matching route with reason "excluded by caller".
Hard filters also retain role and producer tier floors, pool reachability,
exhaustion, scoped refusals and picker fit. Planner and review roles require
strong or frontier; a checker never runs below any producer's tier.

The ladder first prefers a maker different from every producer, then the same
maker on a different model line, then a producer's own line. Within each group,
pools with unknown pace or pace below `lowWaterMark` (default 0.5), plus the
session pool when its unscoped remaining share is at or below one fifth, sort
after other pools. Otherwise the session pool sorts after every non-session pool
in that group. Next come higher `pools.<name>.preference` (default 0), higher
effective pace, then family/runtime name. Session buffer uncertainty warns; it
does not exclude a route. Exhaustion still excludes it. Aim for every pool to
reach its reset near empty. Do not report pool numbers unless asked.

Return the top three candidates, spreading across pools where possible, plus a
retained producer's own model line or else the caller's model line as last
resort, without duplicating a top-three candidate. An optional `caller` record
attests the current `family`, concrete `model` and actual `effort` so the helper
can retain `action=continue-self` when needed. The last resort keeps hard
filters and the recursion floor: non-interactive or external delegates get
native routes or themselves. Report no qualified route only when every route is
hard-filtered and the caller cannot run itself; retain exclusions and report the
loop failure with empty candidates and a non-zero exit. Unmeasured candidates
carry explicit budget/session uncertainty.

Tier and pace do not establish role fit, trial eligibility, live availability or
cross-maker independence. Supply `taskSummary`, nullable `proposerFamily`,
`nonInteractive`, compact role requests and optional caller identity. Routes
come from the manifest's enabled calling-runtime and automatic extra-runtime
reaches; manual-only runtimes stay manual. The helper resolves a concrete Nix
pin first, else the highest matching visible local catalog version. Codex uses
its local models cache; a listed pin uses that entry's supported efforts,
otherwise its Nix-declared efforts are retained and `launch.effortSource` names
the fallback. Unresolved routes are dropped with a JSON reason.

A refused request exits 2 with every problem as `{"path", "message"}` records in
a stdout `invalid-request` document and runs no Reader or picker; fix the named
paths, and report a `manifest.` path to the user as a configuration fault. The
helper judges hard-eligible families with its tool-free one-shot picker before
ladder ranking. Entries run in pool order, not list order; the proposer model
line is allowed. Missing/null proposer identity or no usable picker emits
`WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.`
followed by ` Unavailable: <reason>.` suffixes naming identity, missing entries,
eligibility refusals, local preparation or attempt failures. Report the warning
to the user and use the returned tier/pool ranking. Preserve every trial, mode
and tier restriction. The helper may run its configured tool-free picker even in
nonInteractive contexts; it launches no worker delegates. Canonical launch lines
are routing specifications for the orchestrator to bind to native tools or named
launchers.

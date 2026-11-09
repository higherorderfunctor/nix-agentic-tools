Before the first delegate, invoke the absolute `delegate-routing-plan` command
rendered in this runtime's skill with the requested roles and caller-observed
`--launch-context`. Use its decision as canonical; do not reproduce Reader
discovery or pace arithmetic manually. The helper must run the Reader of every
pool in the Pools table, including pools outside this runtime's launch targets;
the Reader column names the command, not a separate registration per target
runtime.

The helper ranks fitting measured candidates by worst-window pace, using each
window's reported length; a monthly pool is paced against its month, not the
week. Pool pace and buffer use unscoped windows only; at least one is required.
A scoped window `<window>:<model>` matches an exact configured family name in
that pool and limits only that family's candidates: their effective pace is the
worse of the pool pace and scoped paces, and 0% excludes only that family. A
consistent unstarted scoped window (0% used, 100% remaining, null reset) adds no
limit; malformed scoped windows warn and refuse only their named family without
failing the pool. Unknown scopes warn with the window name without failing the
pool. Failed or incomplete Readers and ambiguous accounts are unmeasured with
reasons: exclude them while fitting measured pools exist and report that once
per snapshot. With no measurable fitting pool, use fit alone and report
budget/session uncertainty. Never treat exhaustion as unmeasured.

The configured session pool drains last: select a candidate only when every
other fitting measured pool is behind or level in pace (comparing effective
candidate paces) and its minimum remaining share across applicable windows is
strictly more than a fifth; only unscoped windows apply to this buffer. That
fifth is the buffer for the person using the session; unknown session identity
cannot certify it. Aim for every pool to reach its reset near empty. Do not
report pool numbers unless asked.

Tier and pace do not establish role fit, trial eligibility, live availability or
cross-maker independence. Supply that evidence in the launch context and honor
exclusions. For finder, first-check, second-check and judge, never step down a
tier; report a loop failure when no qualified strong/frontier route is
available. The helper launches no delegates; canonical launch lines are routing
specifications for the orchestrator to bind to native tools or named launchers.

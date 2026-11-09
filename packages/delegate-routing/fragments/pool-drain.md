Before the first delegate, invoke the absolute `delegate-routing-plan` command
rendered in this runtime's skill with the classifier exchange in Routing helper
and caller-observed `--launch-context`; reuse a valid receipt when the actual
unit-role inputs match. Use its decision as canonical; do not reproduce Reader
discovery or pace arithmetic manually. The helper must run the Reader of every
registered pool listed in its output, including pools outside this runtime's
launch targets; Reader commands belong to registered pool keys, not separate
registrations per target runtime. Collection precedes request and saved-plan
validation. On success and failure, stdout contains JSON with `status` (`ok`,
`classification-required` or `error`), pools and diagnostics; an unreadable
inventory explicitly reports `inventory-unavailable` rather than claiming all
pools were observed. Stderr lists every registered pool alphabetically as
`pool=<name> status=<status>`. Each failed Reader command emits one WARNING
naming all registrations sharing it, with a bounded reason and the instruction
to report the failure to the user. Report that failure to the user even when
another pool permits routing. Missing Readers receive explicit unmeasured
warnings; scoped errors warn only for their families. Keep numerical
measurements in JSON, not status lines.

A successful check-plan does not reserve capacity. Before every planned
unit-role launch, use `--dispatch` with its saved receipt and current facts as
specified in Routing helper. Every dispatch collects all pools again; choose
reviewers using recorded actual participants after the writer finishes.

The helper ranks fitting measured candidates by worst-window pace, using each
window's reported length; a monthly pool is paced against its month, not the
week. Equal effective pace puts non-session pools before the session pool, then
lower qualitative family cost, then family name and runtime. Cost never inverts
pace or session priority, including when all pools are unmeasured. Pool pace and
buffer use unscoped windows only; at least one is required. A scoped window
`<window>:<model>` matches an exact configured family name in that pool and
limits only that family's candidates: their effective pace is the worse of the
pool pace and scoped paces, and 0% excludes only that family. A consistent
unstarted scoped window (0% used, 100% remaining, null reset) adds no limit;
malformed scoped windows warn and refuse only their named family without failing
the pool. Unknown scopes warn with the window name without failing the pool.
Failed or incomplete Readers and ambiguous accounts are unmeasured with reasons:
exclude them while fitting measured pools exist and report that once per
snapshot. With no measurable fitting pool, use fit alone and report
budget/session uncertainty. Never treat exhaustion as unmeasured.

The configured session pool drains last: select a candidate only when every
other fitting measured pool is behind or level in pace (comparing effective
candidate paces) and its minimum remaining share across applicable windows is
strictly more than a fifth; only unscoped windows apply to this buffer. That
fifth is the buffer for the person using the session; unknown session identity
cannot certify it. Aim for every pool to reach its reset near empty. Do not
report pool numbers unless asked.

Tier and pace do not establish role fit or live availability. Supply observed
techniques and an independent capability receipt, and honor the helper's
exclusions, including its trial and maker exclusions from family data. For
finder, first-check, second-check and judge, never step down a tier; report a
loop failure when no qualified strong/frontier route is available. The helper
launches no delegates; canonical launch lines are routing specifications for the
orchestrator to bind to native tools or named launchers.

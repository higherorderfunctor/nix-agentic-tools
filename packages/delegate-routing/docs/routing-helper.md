# Routing helper decisions

The routing helper selects a launch for each requested role. It combines the
runtime's manifest, the caller's observed techniques and the registered pools'
usage readings. The
[helper contract](development.md#deterministic-routing-helper) describes the
launch context, picker and pace formula.

## Reader failures

A pool with no registered Reader command stays eligible as unmeasured; it has no
usage reading to fail.

A timeout or nonzero exit gets one retry after two seconds. Invalid JSON, an
invalid envelope or multiple accounts in successful output fail immediately. If
execution or parsing fails, all pools sharing the command are unreachable for
this invocation, even for fit-only selection. This status describes access to
usage data. The inference endpoint's availability is still unknown.

Each snapshot reports a shared command's failure once, naming all its
registrations. A dropped window warning identifies the pool and window. JSON
contains all warnings. Failure warnings and fallback notices also go to stderr.

## Incomplete windows

A bad pace leaves a readable remaining share intact. An unreadable unscoped
share makes the buffer unknown unless another unscoped share is zero. A proven
zero sets pace and buffer to zero and keeps the pool measured. Otherwise the
pool needs a usable unscoped window to have a pace. Unmeasured pools retain
their readable shares. A route without a pool binding has no measured budget.

An idle window (0% used and 100% remaining) adds no limit to other windows,
including when it is scoped to a family. A malformed or exhausted scoped window
rules out only its family. An unknown scope produces a warning naming the window
and leaves the pool eligible.

## Session pool and fallback

The helper removes exhausted pools, refused families and session routes with
insufficient buffer before comparing candidates. Use the session pool only when
every other fitting measured pool is behind or level in effective pace and the
session pool's smallest unscoped remaining share is strictly over one fifth.
That share protects the user's session. Unknown identity prevents certification.
An unmeasured pace or unknown buffer rules out the configured session pool.

When no measured candidate survives, the helper can return a fit-only route. If
a role has no reachable candidate, its candidate list is empty, its exclusions
remain in the JSON and the command exits nonzero.

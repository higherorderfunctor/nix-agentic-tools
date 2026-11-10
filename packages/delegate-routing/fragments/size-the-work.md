Pick a model family whose "use for" fits the task and whose "avoid for" does not
rule it out. Role fit and trial eligibility are separate from budget and effort.
Quality versus spend is consumer policy; there is no universal cheapest model or
model-before-effort ordering.

Resolve each candidate's base effort from a non-null role override, otherwise
its machine `defaultEffort`, for every technique. Consumers can override the
existing `families.<vendor>.<family>.defaultEffort` option. Sol defaults to
medium and Go Kimi K3.1 Pro to max; a configured glm can set high (no glm preset
is shipped). Prose guidance is not a runtime default lookup.

The fixed package scale is `minimal < low < medium < high < xhigh < max`.
Observed `efforts` is an unordered support set. An avoided-family fallback
advances the resolved base to the next supported setting, including when the
base came from an explicit override; at the highest supported setting it stays
unchanged. Unsupported overrides are refused, never silently lowered. State the
resolved and launch efforts and disclose fallback metadata.

Observed `efforts: []` explicitly certifies omission support: every candidate
launches without effort, regardless of its role request, family default or
avoidance. It does not mean unknown support. Keep JSON effort null and omit the
actual tool argument, CLI flag and frontmatter pin. Never pass the strings
`None` or `null`. A technique requiring an effort value is unavailable for that
candidate. Otherwise set model and resolved launch effort explicitly whenever
the tool allows it. Unpinned inheritance is unsized unless the delegate's known
launch values match the canonical selection.

When "Orchestrator session" is enabled, follow its handoff order even for a
quick look or review. When that entry is disabled, these rules apply instead:
answer a documented fact from the few files that decide it, or ask the user; do
a quick review from the few files that decide it, and fan out when that check
shows the work is wide; when unsure, do the in-session pass and offer the deeper
one with its rough cost. In either mode, an interesting or security-adjacent
subject alone is not a reason to fan out.

Name each role's model and effort in one line in the launch message to the user,
or in the report to the orchestrator when non-interactive, so it can be
overridden.

Applying a reviewer's located list is mid-tier work at medium effort. Keep top
tiers for finding, judging and design.

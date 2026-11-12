The helper's picker judges which family fits the task and role; never choose a
family by hand from prose. Role fit and trial eligibility are separate from
budget and effort. Quality versus spend is consumer policy; there is no
universal cheapest model or model-before-effort ordering.

Resolve effort from the model line's machine `defaultEffort` on its supported
levels, ordered by the package scale
`minimal < low < medium < high < xhigh < max`. Consumers can override
`families.<vendor>.<family>.defaultEffort`; Sol defaults to medium, GLM to high
and Go Kimi K3.1 Pro to max. Prose guidance is not a runtime default lookup.

For a role checking nobody, `effort` is a signed step offset such as `+1` or
`-1`, or null for the default. For a checking role, supply `producers` with each
model line's `family` and actual launch `effort`. The helper computes each
producer's offset from its own default, takes the largest, and applies it to the
checker's default. The same model line gets one extra step. Clamp to the
supported endpoints. For example, Opus at its medium default selects GLM at its
high default; Opus at high (+1) selects GLM at max.

Routes and supported effort levels come from the generated manifest and local
model catalog. An empty resolved support list means launch without effort: keep
JSON effort null and omit the actual tool argument, CLI flag and frontmatter
pin. Never pass the strings `None` or `null`. A technique requiring an effort
value is unavailable for that candidate. Otherwise bind the helper's model and
launch effort exactly. Unpinned inheritance is unsized unless the delegate's
known launch values match the canonical selection.

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

Applying a reviewer's located list is mid-tier work at the selected model line's
default effort. Keep top tiers for finding, judging and design.

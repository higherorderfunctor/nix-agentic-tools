For finder, first-check, second-check and judge, use the rendered
`delegate-routing-plan` command with a receipt for the actual review brief and
observed launch evidence. Prepare and accept an independent classification when
that receipt is missing or stale. It enforces the strong/frontier floor and
declared maker independence before pool ranking; never step down a tier; report
a loop failure if no qualified route remains. Supply the writer family in each
review role's `writer` field and, when judging cuts, the proposer family in
`cutProposer`. Unknown makers cannot certify independence. A tier or maker pass
does not establish task fit. Family `trial = true` excludes second-check and
judge; finder and first-check still require tier, maker and fit eligibility.
Honor those exclusions before launch.

Review every change with all three checks below, each in a fresh context. The
first check, the second check and the judge each use a model maker other than
the writer's. Use different models for the two checks where possible. Report
disagreements only. Hand the whole review as one job to a delegate using an
independent model maker on a runtime that runs its own subagents (the technique
table's "Runs own subagents" column), such as `codex exec` for work Claude
wrote. It runs all three checks itself, mixing models, and returns each issue's
outcome with evidence. When no such runtime is reachable, split the roles from
this session through tools that pin model and effort: Agent calls that name a
generated agent file for cross-maker checks from a Claude writer, the Workflow
tool's agent call, or an external launcher (`claude -p`, `codex exec`). Skipping
the maker requirement because one tool's enum lacks the model is a loop failure;
report it as one.

**First check:** gets the draft, the description's guarantee claims (never its
review history or the writer's notes) and the rubric file verbatim. Grades the
description's claims first, then every rubric row in order: pass with the line
that meets it, fail with location and evidence, or unknown with what would
settle it. A guarantee with no enforcing line in this diff is an issue of at
least medium severity. Then lists issues no row covers, checking each against
the draft itself. For each fail or issue, returns its location, the row or
requirement it breaks, evidence, whether it holds, and a proposed severity; if
uncertain, returns the open question that would settle it.

The reviewer, not the writer, searches for dead code: removed names, dead
branches, checks pinning removed behavior, stale prose and shims. It lists what
it searched, so an empty result differs from not looking.

**Second check:** independently checks the draft for what would make each
supplied issue wrong. Returns concede, or rebut with its own evidence.

**Judge:** rules on every proposed cut, rebutted issues, high-severity
concessions and a small sample of concessions below high severity to check for
lazy agreement. Returns accepted with final severity, rejected, or unresolved
with the open question; names which point it set aside and why. A conceded issue
the judge does not sample is accepted at the first check's proposed severity.

Family `trial = true` marks a family without an established review track record
in this setup; consumers may override it as that record changes. Blend makers
across review roles.

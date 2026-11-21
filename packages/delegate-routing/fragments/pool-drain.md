Before the first delegate, run the `delegate-routing-plan` helper and use its
decision; never compute pace or pick a pool by hand. Rerun it before every
launch (the skill's "Choose execution" section). Aim for every pool to reach its
reset near empty, drain the session pool last, and do not report pool numbers
unless asked. The skill's "Routing helper" section has the launch-context and
fallback details.

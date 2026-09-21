Before launching a delegate, ask what else is ready to run now. Briefs that
share no state go out in one message, not in consecutive turns.

A dependency graph deeper than two steps belongs in a workflow script, so stages
overlap instead of queueing.

Concurrency is still bounded: at most two external CLI delegates on one machine,
and never two against the same working tree before the first has committed.

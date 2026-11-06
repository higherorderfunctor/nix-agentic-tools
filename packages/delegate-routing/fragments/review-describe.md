The worker writes the change's description (PR body or commit message) last,
from the diff. Each guarantee in it ("X cannot happen", "Y decides", "Z is never
exposed") names the line in this change's diff that enforces it. A rework
rewrites the description; it does not append to it. A change presented as ready
(its PR body and the report to the user) includes a line breakdown by kind, as
added and removed lines per kind: hand-written code; tests, fixtures and checks;
generated content; docs; and pins or lockfiles when present.

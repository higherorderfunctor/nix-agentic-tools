The worker writes the change's description (PR body or commit message) last,
from the diff. Each guarantee in it ("X cannot happen", "Y decides", "Z is never
exposed") names the line in this change's diff that enforces it. A rework
rewrites the description; it does not append to it. A change presented as ready
(its PR body and the report to the user) includes the number of files touched
and a line breakdown by kind, as added and removed lines per kind: hand-written
code, counting shipped agent-instruction prose (skills, fragments, prompts);
tests, fixtures and checks; generated content; docs; and pins or lockfiles when
present. A deleted file counts as one removed line.

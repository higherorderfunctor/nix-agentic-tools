The worker writes the change's description (PR body or commit message) last,
from the diff. Each guarantee in it ("X cannot happen", "Y decides", "Z is never
exposed") names the line in this change's diff that enforces it. A rework
rewrites the description; it does not append to it.

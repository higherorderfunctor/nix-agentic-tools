# Resolve a review target

The runtime entry skill supplies the installed resource paths and profile. A
review request authorizes acquisition and review, never publication. Native
workers perform the review; the entry session prepares inputs and monitors it.

Accept an MR URL, a project-scoped IID, or an explicit prepared bundle. Resolve
GitLab's canonical host, numeric project ID and MR IID through configured glab
or actual MCP tool schemas. A bare IID uses the current repository's unambiguous
project context. Ask only for missing or conflicting target information. Do not
ask for tokens or invent model IDs, tools or remote state.

For an MR, reuse a frozen input only after `transport/local.py verify-freeze`
succeeds and the target and intended head match. If no head was explicitly
pinned, read current metadata before deciding to reuse input. Otherwise write a
pull request using `transport/API.md`. Choose a new detached checkout path and
artifact directory without resetting or cleaning user work. Pull reads all
comments and creates actionable intake; completion requires a verified frozen
receipt, not agent prose.

For a prepared local bundle, follow `shared/API.md` and respect its explicit
source pin. Allocate distinct writable run/arm directories outside that pinned
checkout; Kiro also needs its run directory under the launch workspace. Default
the review pass to 1. Read limits from the installed profile. Nonempty supplied
intake needs at least two waves; the default three covers it. Use the same
frozen bundle/intake for A/B comparison, with separate state and only explicit
same-arm history. Never import the other arm's judgments.

After pull, use the actual receipt's bundle and intake paths. Empty intake adds
no work; nonempty claims enter the whole review loop. Return the local report
paths with complete/incomplete status and unresolved work. Preserve failed runs
and receipts for inspection and explicit recovery.

Review roles ignore author/user identity and assume LLM-authored code a human
must maintain. First-pass cleanup includes concrete unnecessary machinery and
duplicated responsibility; later passes narrow to substantive remaining defects.
Do not soften findings for the requesting user or manufacture defects to meet a
quota. Each accepted factual leg needs reproducible cited evidence.

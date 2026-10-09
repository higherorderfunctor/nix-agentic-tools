# GitLab transport

Pull and push are separate native jobs outside the review core. A review request
authorizes pull and review. Push requires an explicit request naming the report
and destination. The review workflow never invokes push.

Use the installed entry skill for an MR URL or project-scoped number. It
resolves the target through existing glab/MCP setup, writes the request
described in [API.md](API.md), and launches Kiro or returns a Kimchi command.
Models and efforts come from the selected runtime's lens role; no separate
transport profile is needed. Kiro's installed pull/push agents use configured
tools and receive the validated job through the step prompt.

`materialize.py --phase pull|push --profile PROFILE --request REQUEST --workspace WORKSPACE`
returns a Kiro `workflow` path. Validate its complete JSON object, then pass
that path to native `run_workflow`. It writes no agent definitions. Recover with
the original recipe and request; the receipt guards reject changed bindings.

Kimchi's installed transport entries accept
`{"request_file":"/absolute/request.json"}`. The entry skill provides their
actual absolute paths. Load the pull or explicitly authorized push entry with
`/workflow run PATH --input JSON`. A saved native workflow prepares and verifies
the deterministic receipt around one fresh transport worker.

The local helpers never contact GitLab. `local.py freeze` and `verify-freeze`
bind a complete snapshot to pinned source; `plan`, `observe` and `begin` bind a
selected publication and preserve uncertain writes for reconciliation. Read-back
verification determines success. Review output includes bot attribution and
collapsed evidence chains; publishing preserves that Markdown byte-for-byte.

Configured authentication stays with glab/MCP. Acquisition and review can use
the same sandbox; separate directories and tool instructions do not claim
credential isolation. The two A/B review arms share frozen input but use
distinct run state.

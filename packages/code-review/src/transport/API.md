# Local pull/push contract

`python3 transport/local.py COMMAND` prints JSON and exits 2 on refusal. This
helper performs local Git reads and artifact bookkeeping only. Native agents own
remote acquisition, pagination, mutation and error interpretation through
configured glab or GitLab MCP. No HTTP client, scheduler or credential reader
exists here.

Authentication belongs to the configured glab CLI or MCP server. Do not read or
copy credentials. A request defaults to `transport: "glab"`; selecting
`transport: "mcp"` also supplies the actual configured `mcp_server` and
`mcp_tools` names. These identify the tools the transport worker must use, not
credentials or instructions from the merge request.

## Native request files

Both runtimes consume an absolute JSON request file. All artifact and checkout
paths below must be absolute. Both phases require `schema_version: 1`, `target`
with string `host`, positive decimal `project_id` and `mr_iid`, and `snapshot`.
A URL or IID is resolved by the entry skill before writing this request.

Pull also requires `checkout` (a new authorized detached checkout path) and
`output_dir` (a fresh frozen-artifact directory outside that checkout). Set
`intake_output` for the extracted claims file. Optional `house_rules`, `intake`
and `prior_snapshot` name existing supplied files. Snapshot and generated intake
are outputs and need not exist before pull.

Push requires `report_json`, `report_md`, `publication_dir`, `observation_file`
and `action` (`create`, `reply` or `update`). Reply needs `discussion_id`;
update also needs `note_id`, authenticated `owner_id` and `baseline_hash`. These
must come from explicit publication authorization and fresh remote observation;
never fill them from report prose. The selected complete report and original
snapshot must already exist.

Kimchi's workflow input is `{"request_file":"/actual/request.json"}`. Kiro's
materializer embeds the validated request and original digest in its saved
recipe. Reuse that same recipe for recovery; generating over it is refused so a
changed request cannot replace the original binding.

## Normalized snapshot, version 1

The agent writes this shape after complete pagination:

```json
{
  "schema_version": 1,
  "complete": true,
  "observed_at": "2026-10-08T20:00:00Z",
  "target": {
    "host": "gitlab.example.com",
    "project_id": "123",
    "mr_iid": "45",
    "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "start_sha": "cccccccccccccccccccccccccccccccccccccccc"
  },
  "before_refs": {
    "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "start_sha": "cccccccccccccccccccccccccccccccccccccccc"
  },
  "after_refs": {
    "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "start_sha": "cccccccccccccccccccccccccccccccccccccccc"
  },
  "discussions": [
    {
      "id": "remote-discussion-id",
      "resolved": false,
      "notes": [
        {
          "id": "987",
          "body": "Comment text",
          "updated_at": "2026-10-08T19:00:00Z",
          "author": { "id": "1234", "username": "reviewer" }
        }
      ]
    }
  ]
}
```

IDs normalize to strings. Refs are full lowercase Git object IDs. Before and
after refs must equal the target. Duplicate discussion/note IDs refuse. The
helper trusts the agent's completeness assertion; it cannot prove pagination
from this shape. Remote reads are not an atomic snapshot. Preserve additional
remote fields in snapshot.json when useful; the helper does not interpret them.

## Pull

`freeze --snapshot FILE --checkout PATH --output-dir NEW_DIR` accepts optional
`--house-rules FILE` (text list) and `--intake FILE` (`{"claims": [...]}`). No
fetch occurs. Base/head commits must exist locally, checkout HEAD must equal
head and the checkout must be clean. The review diff is local
`git diff base head`, not a GitLab inline-anchor universe.

Freeze writes bundle.json, review.diff, snapshot.json, intake.json,
transport.json and freeze-receipt.json. It never overwrites an existing output
directory. The target ID is `gitlab:{host}:{project_id}!{mr_iid}`. The bundle
feeds shared prepare; initial intake is a separate command and requires at least
two review waves under the current middle-core contract.

The receipt has `state: "frozen"`, `ready: true`, absolute artifact paths and
`hashes` containing target, snapshot digest, bundle/diff/intake SHA256 values
and note-body hashes. `verify-freeze --frozen-dir DIR` checks those artifacts
and the current clean source pin and returns that shape. Both A/B arms reuse the
same frozen bundle; their review state remains separate.

Snapshot/sidecar preserve author identities. Review comments use a fixed
allowlist: discussion ID/resolved/resolvable; note ID/body/timestamps/position/
system. Author identity fields are omitted, but body text can still identify
people. This is not complete anonymization. Claim extraction and changes to
substantive comments belong to the pull agent/intake, not publication.

`observed_at` must be ISO format with an explicit timezone. Freeze and plan
allow historical observations. Publication observe requires an observation no
older than five minutes, allowing at most sixty seconds of future clock skew;
begin rechecks that bound before recording intent. This checks the supplied
timestamp, not whether the agent actually performed a remote read.

## Push

`plan --snapshot FILE --report-json FILE --report-md FILE --publication-dir NEW_DIR --action create|reply|update`
requires a complete version 1 report whose target exactly matches the snapshot.
Reply requires `--discussion-id`. Update additionally requires `--note-id`,
`--baseline-hash` (SHA256 of current body), and `--owner-id` (authenticated
publisher user ID matching note.author.id). Update also requires an existing
report marker. Create/reply reject update-only fields. The agent establishes the
authenticated identity; the helper cannot attest who supplied that ID.

Plan preserves the selected Markdown as a prefix and appends a stable hidden
`review-ab:report` operation marker. It seals plan.json and request.json with
target, report/input hashes and operation ID. Revisions need a new plan
directory. There is one report per operation; no inline anchors, deletion or
resolution mutations are supported.

`observe --publication-dir DIR --snapshot FRESH_FILE` validates target/refs and
selected update baseline. An exact unique marker/body observation adopts a
verified receipt. Duplicate markers, conflicting bodies and wrong target IDs
refuse. Missing matches after intent remain uncertain, even if no note is seen.
Missing matches after verification also make closeout uncertain; they do not
erase the earlier receipt. Observe before begin and again after the mutation.

`begin --publication-dir DIR` requires a ready preflight and atomically records
started before returning host/method/endpoint/request path. The agent then
executes that one mutation. Started/uncertain/verified operations cannot begin
again. There is no retry override in this slice; the agent reports ambiguous or
rejected attempts with evidence rather than making a new plan as a retry.

`status --publication-dir DIR` returns `state`, plan digest, preflight and
receipt, target/action, report JSON/Markdown hashes, input digest and body hash.
Only `state: "verified"` plus a receipt is successful delivery. A failed fresh
observation blocks an earlier ready/verified control rather than reusing it. The
receipt includes operation ID, discussion/note IDs, body hash, observation
timestamp and snapshot digest. The helper takes an exclusive local lock and uses
atomic ledger writes. Timestamps and remote mutation responses alone are not
verified delivery. Fresh pre-read followed by write is not atomic CAS; there is
no exactly-once guarantee. Keep publisher state out of A/B review runs. Complete
processing may still contain unresolved/filtered verdicts; the selected report
retains their accounting unchanged.

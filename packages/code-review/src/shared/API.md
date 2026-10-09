# Shared review core API

Contract version 1. Native adapters schedule phases and fresh single-duty
agents; this Python CLI only validates, persists and renders their work. No
remote service access or model calls exist here.

Run `python3 shared/review.py COMMAND`. Every command except preparation takes
`--run-dir ABSOLUTE_PATH --arm SAFE_EXPERIMENT_SLUG`. JSON is printed to stdout;
contract violations exit 2.

## Prepared input

`prepare --input bundle.json --run-dir PATH --arm ARM --runtime kimchi|kiro-cli --profile profile.json --pass 1|2|3`
creates a new run. Required bundle fields:

```json
{
  "schema_version": 1,
  "target": { "id": "review-123", "base_sha": "commit", "head_sha": "commit" },
  "checkout": "/absolute/pinned/checkout",
  "diff": "/absolute/prepared.diff",
  "comments": [],
  "house_rules": ["Explicit target policy"],
  "prior_report": "/absolute/optional/same-arm/report.json"
}
```

`house_rules` is an optional text list, snapshotted and supplied to every role.
`comments` may instead be an absolute JSON file path. The checkout HEAD must
equal `head_sha`, and tracked or untracked source changes refuse. Ignored build
artifacts are excluded. Source cleanliness and the tree pin are checked again
for worker payloads. The run directory must be outside the pinned checkout.
`--profile` is optional opaque JSON; runtime is required. A run copies the input
diff and comments and records digests of the input, helper, rubric and prompt
versions. Both arms must receive the same prepared input. Prior reports are
explicitly supplied, must belong to this arm, target and identical profile
digest, and are context rather than automatic suppression rules. An absent prior
is valid. State never searches another run directory.

## Native phase loop

1. `tasks --stage lens`: one proposal task per bounded diff chunk.
2. Submit each task with `submit --task ID --result FILE`.
3. `tasks --stage refine`: one evaluator with all proposals, chunks and
   coverage.
4. Submit refine; `tasks --stage surface`: one task per refined lens/chunk
   partition.
5. Submit surface; `tasks --stage dedupe`: one evaluator receives all candidates
   and conservative pair proposals.
6. Submit dedupe; `tasks --stage adjudicate`: one task per distinct claim.
   `claim` supports lens and surface drains too; `--control-only` returns the
   task ID, next_role and completed_roles without claim text for path-only
   coordinators. A horizontal slot may `claim --stage adjudicate --worker NAME`,
   inspect its returned task, and run fresh evidence, optional defense and judge
   agents in sequence. It then claims the next item.
7. `payload --task ID --role evidence|defense|judge` returns narrow role input.
   `submit --task ID --role ROLE --result FILE` records each result. Evidence
   can request independent defense; judge cannot run until evidence and
   requested defense exist. Judge completion receipts finish the claim.
   `release --task ID --worker NAME` explicitly relinquishes interrupted work;
   leases never expire implicitly.
8. `tasks --stage finalize`: one holistic evaluator sees all judgments and
   citations. Submit its result.
9. `next-wave` returns `{continue: true}` when discoveries or steering need the
   entire loop, otherwise `{continue: false}`. New discoveries enter the next
   wave, never an in-flight task snapshot. Chunks are bounded by --chunk-lines
   (default 100) and --chunk-chars (default 12000). Nontext changes receive
   explicit metadata chunks. Oversized individual context is truncated with a
   digest and unresolved coverage diagnostic, never clean completion.

`--max-waves` on prepare defaults to 3; exhausted work remains
unresolved/incomplete. 10. `report` writes `report.json` and `report.md` and
returns their paths plus status. Calling it early is valid and reports missing
receipts as incomplete; it never invents accepted work.

`status` returns wave, stage, pass, complete, pending_tasks, pending_intake and
budget_exhausted. Every command updates status.json and status/STAGE.json, whose
drained boolean requires all stage receipts. `prepare` returns
run_dir/arm/input_digest; `tasks` returns {stage,wave,tasks}; `payload` returns
{role,task_id,prompt,input}, with task_id also in input; `submit` returns
{task_id,role,complete,needs_defense,next_role,accepted,exhausted,attempt,error};
`claim` returns {task,drained}. Role prompts include the output JSON schema from
schemas.json $defs[role]. Python checks relational coverage and citations as
well as these structural fields. Journal events include timestamps, and report
role_receipts count persisted stage results; those are not model-call or token
telemetry.

`intake --input FILE` accepts
`{"claims": [...], "steering": "optional user text"}` at any time. Exact request
replay is content-idempotent; an optional request_id distinguishes intentional
identical requests. Steering creates a new coverage/lens task even without a
claim. Every discovered claim enters intake, coverage, rubric assignment,
surface, dedupe, evidence, judgment and finalization. Intake after finalization
forces another wave before completion.

## Result shapes

Every result is a JSON object with `task_id` equal to its task. Unknown IDs,
foreign-arm access, conflicting replay and malformed citations refuse before
mutation. Same-content replay succeeds.

- Lens:
  `{"task_id": ID, "lenses": [{"name": "...", "questions": ["..."], "ecosystem": "...", "corpus": "...", "confidence": "low", "basis": [], "banks": ["correctness-security", "docs", "house", "maintainability-reuse", "testing"]}]}`.
- Refine:
  `{"task_id": ID, "lenses": [{"id": "...", "name": "...", "questions": ["..."], "ecosystem": "...", "corpus": "...", "confidence": "low", "basis": [], "banks": ["correctness-security", "docs", "house", "maintainability-reuse", "testing"], "chunk_ids": ["..."]}], "dropped": [{"reason": "..."}]}`.
  Every chunk must receive a lens with all five baseline banks. Non-low
  confidence requires cited basis. Low confidence uses generic questions. A lens
  covering several chunks creates separate bounded surface tasks sharing that
  lens specification.
- Surface:
  `{"task_id": ID, "candidates": [{"claim": "...", "locus": {"file": "relative/path", "side": "new", "line": 12}, "related_loci": [], "citations": []}]}`.
  An explicit empty list is valid. Discovered claims use this same candidate
  shape. Surfacing must carry each supplied intake claim with intake_id equal to
  its intake entry ID; an empty result cannot discard intake.
- Dedupe:
  `{"task_id": ID, "groups": [["candidate-id", "..."]], "dropped": [{"id": "candidate-id", "duplicate_of": "retained-candidate-id", "reason": "..."}]}`.
  Every candidate occurs exactly once in groups or drops. Distinct claims at one
  locus must remain separate. Merge uncertainty means keep separate. Drops must
  name a retained duplicate; validity rejections belong to evidence and
  judgment. Every intake claim remains represented in a surviving group. Drop
  reasons are journaled. Optional supersedes: [{candidate_id, prior_id, reason}]
  replaces an earlier semantic claim after complete new adjudication. Earlier
  outcomes are dedupe context; exact normalized claim/locus identity is replaced
  only after the full new evidence/judgment loop, never by a fuzzy script match.
- Evidence:
  `{"task_id": ID, "citations": [...], "verify_path": "replayable check", "needs_defense": false, "discoveries": [...]}`.
  A `narrative` string is optional and journal-only.
- Defense:
  `{"task_id": ID, "citations": [...], "reason": "...", "discoveries": [...]}`.
  Independent challenge receives claim/locus/rubric, not prosecution narrative
  or evidence.
- Judge:
  `{"task_id": ID, "disposition": "accepted|rejected|unresolved", "severity": "none|low|medium|high|critical", "reason": "...", "citations": [...], "verify_path": "...", "discoveries": [...]}`.
  Acceptance requires citations and a nonempty verify path. One verdict per
  claim.
- Finalize:
  `{"task_id": ID, "decisions": [{"id": "claim-task-id", "disposition": "accepted|rejected|unresolved", "severity": "none|low|medium|high|critical", "reason": "..."}], "discoveries": []}`.
  Exactly one decision per distinct claim across all waves, including earlier
  accepted/rejected/unresolved outcomes. It may contract acceptance and
  severity; severity cannot exceed the independent judge. It but cannot accept a
  rejected/unresolved claim without renewed evidence through intake.

  Optional `presentation_groups: [{title, claim_ids: [ID, ...]}]` groups
  independently judged claims by a concrete shared mechanism/error class or
  remedy. This never merges verdicts or accepts all members as a family. Unknown
  IDs and duplicate membership refuse; ungrouped claims receive singleton
  groups. Semantic dedupe remains a separate same-defect decision. Dropped
  restatement candidates retain their instance pointers in the surviving claim's
  members. Within one adjudicated claim, physical locations (file/side/line/end
  line) render once; each instance keeps all candidate IDs, distinct claim
  wordings and citations as provenance. Distinct claims at the same location
  still retain separate outcomes/verdicts. JSON outcomes expose every instance
  and narrow public evidence/defense/judge/finalizer substantiation; private
  narrative fields stay out of reports. Markdown shows every claim's disposition
  and all instances, with complete evidence/replay text inside escaped
  collapsible details.

Report Markdown begins with the common AI-disclosure banner, without an invented
authenticated runner. The supplied Peer Communication reference lives at
references/peer-communication.md, is part of immutable helper/prompt version
provenance, and is supplied to finalization in both arms. Model-supplied strings
are rendered as text, not Markdown links or raw HTML. Cite-or-stop guards
require citations and a replay path for acceptance; the helper does not certify
that the checks were executed or their conclusions are true.

A citation is
`{"file": "relative/path", "line": 12, "supports": "claim supported"}` or
`{"url": "https://...", "version": "pinned version", "supports": "..."}`.
Optional `end_line` must be at least `line`. File paths must stay inside
checkout; existing symlink escapes refuse. Workers only read pinned source,
never modify it. Citation validation is structural, not a claim that evidence
proves the finding. The source pin and schema guards are rechecked at
payload/report boundaries.

## Pass policy and journal

Pass 1 surfaces broad correctness, security, testing, docs and
maintainability/cleanup concerns for code a human must inherit. Pass 2
emphasizes substantive remaining defects; only medium/high/critical accepted
findings publish. Pass 3 publishes high/critical blockers and serious risks.
This severity floor is deterministic and visible; every verdict, contraction,
filtered finding, steering input and discovery remains in `journal.jsonl`. It
does not waive re-entry, missing workers or unresolved work.

No delivery modes or GitLab effects exist. The JSON/Markdown report is the
actual output consumed by the next skill. A branch target uses exactly the same
report sink.

Identical discovery objects already routed through full intake are journaled as
exact discovery replays rather than recursively requeued. Changed citations,
loci or claim text create fresh intake; fuzzy similarity never automatically
suppresses work. User steering is independent of this discovery replay rule.

The shared validator enforces the same schemas.json output shapes for both arms
(objects, arrays, required fields, enums, primitive types and minimum bounds),
followed by citation/coverage relationships. Quoted Git diff paths are not
supported; unsupported metadata or path encodings refuse explicitly. Content
claims remain agent judgments.

## Comment history and finding intake

Supplied `comments` are evidence/history context for claim adjudication; the
core does not extract findings from arbitrary discussion text. Upstream
extraction is outside this skill. An actionable prior comment that must receive
full coverage/evidence/judgment must also arrive as an intake candidate, for
example
`{"claims": [{"claim": "Earlier comment alleges an unsafe parse", "locus": {"file": "src/parser.py", "line": 12}}]}`
via `intake --input FILE`. Comments alone never assert that every prior finding
was reviewed.

Intake submitted before the initial lens phase is pending next-wave work, just
like mid-run intake. It enters its entire loop after the first wave's holistic
finalization; reserve at least two waves for that pattern. A one-wave budget
leaves such intake explicitly incomplete. No finding extraction or transport
behavior is implied by report completion.

## Submitted-output correction budget

External `submit --proposal-id ID` calls permit one initial proposal and two
corrections per task/role, including JSON parse, schema and relational
rejections. Rejected output returns `accepted:false`, `error`, `attempt` and
`exhausted`; the role may correct in its current context only while not
exhausted during uninterrupted execution. Interrupted Kiro recovery uses a fresh
child without its prior history; Kimchi retains its duty session key. Both
retain the same remaining shared budget. Successful output returns
`accepted:true` with the normal control receipt. The counter persists across
native restart; exact accepted replay is idempotent. Exhausted `payload` refuses
before another role proposal. Missing files and transport errors exit nonzero
without an output-rejection receipt. Native error traces and pending ledger
identify those failures.

Reports contain `submission_attempts` and `native_controls`: requested profile,
wired configuration and explicitly unknown provider-effective settings. These
are not model-call/token/cost telemetry. Coordinator `default` is an omitted
native override with inherited effort unknown when unobserved, not an applied
effort pin or launch gate.

`payload.proposal_id` identifies the next proposal. Write an immutable proposal
file; pass its ID with `submit --proposal-id`. Same ID and bytes replays its
prior receipt without spending another slot, including rejected output. Changed
bytes with that ID refuse. A new proposal ID containing the same invalid content
still consumes an opportunity.

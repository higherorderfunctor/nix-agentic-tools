# Carried negatives — beliefs that were wrong, and how they presented

Mode **C** of this corpus: findings recorded but **not executed**. Every entry
is a belief that was held, acted on, or published, and turned out to be wrong or
misleading.

These are here because **the expensive part of understanding an undocumented
engine is rarely the discovery — it is the wrong turn you take first.** A
negative that names how a mistake _presented_ saves the next reader the
diagnosis, not just the answer.

Captured against **KAS `2.15.1-e20633b4…`** (kiro-cli 2.15.1) unless an entry
says otherwise. Every entry follows the same four fields.

---

## C-1 — Redirecting `KIRO_HOME` appeared to prove global hooks never load

**Belief:** Kiro loads hooks only from `<workspace>/.kiro/hooks/`; the global
`~/.kiro/hooks/` is never read.

**Reality:** global hooks **do** load — the loader scans the home directory in
addition to workspace roots, and a hook whose id is a `$HOME` path is observed
firing inside a project session.

**How it presented:** a probe placed one real hook file under a redirected
`KIRO_HOME` and one in the workspace. Only the workspace hook appeared. The
natural reading — "global scope is not supported" — is wrong, and the probe was
_re-confirmed_ once, which entrenched it.

**Why it fooled us:** the loader resolves its global root from the launcher's
home-dir argument or the process home directory — **not** from `KIRO_HOME`.
Redirecting `KIRO_HOME` therefore **hides** global hooks rather than relocating
them.

**Settled 2026-07-30, from the launcher side — which is where this entry already
said the answer lived.** This entry used to stop by saying that whether a
`KIRO_HOME` redirect can ever reach `hooks/` is a launcher question that _cannot
be settled_ from the engine bundle in either direction, and that the result must
be treated as observed rather than mechanistic. That caution was right about the
engine bundle and wrong about the question: it is answerable by reading the
**client**, and the answer is that there are **two independent roots**.

- **The engine's root is `HOME` only.** It takes a home directory from
  `--home-dir=<value>` and nothing else — its argument reader matches the
  literal `--<name>=` prefix against `process.argv` — falling back to
  `os.homedir()`, which Node documents as `$HOME` when that is defined. The flag
  reaches the agent as a conditional spread that collapses to nothing when the
  argument is absent, so the fallback is not merely likely, it is the only path
  — and there are **two** such constructions, one per transport (stdio and
  multiplexed), spreading it identically, so no transport is a way around it.
- **The client never passes it.** The literal `--home-dir` occurs **zero** times
  in the 555 MB client, against positive controls `--transport=stdio` (2 hits)
  and `--auth=acp-callback` (3) found by the same method in the same file; the
  only `home-dir` hits at all (2) sit inside an unrelated cryptography option
  table. The denominator is the **15 argument names the engine accepts**, of
  which the observed spawn passes exactly those two.

  Two method notes, both of which produced a wrong number here before they were
  understood:
  - **A pattern beginning with `--` must be passed as `grep -e '--home-dir'`**
    (or after `--`). Otherwise `grep` parses it as an option and exits **2**
    with `unrecognized option`. That is not itself a false zero — it is louder
    than one — but the usual shapes silently convert it into one: piping to
    `wc -l` prints `0` from an empty stream, and a `|| true` guard swallows the
    status. C-3's failure mode reached through an error rather than a match.
  - **`grep -c` counts matching LINES, not occurrences**, and this file has
    lines exceeding 180 KB. The counts above are occurrence counts
    (`grep -abo … | wc -l`); the same strings by `grep -c` give 2 / 2, so
    `--auth=acp-callback` reads as 2 rather than 3. Either count supports the
    conclusion, but they are different measurements and must not be mixed inside
    one claim.

- **`HOME` reaches the engine unmodified.** The spawn hands it
  `{...process.env}` with only two Node channel variables blanked and a
  user-agent added.
- **`KIRO_HOME` means something different in the client's own layer:** the path
  **of the `.kiro` directory itself**, not a home directory. Its resolver
  returns `$KIRO_HOME` verbatim when non-empty and otherwise composes
  `join($HOME, ".kiro")`. The two layers build different paths out of the same
  value, which is exactly why a redirect looks like it ought to work and does
  not.

So every engine-side surface moves together under `HOME` and none of them move
under `KIRO_HOME`. Sessions, logs, MCP settings and knowledge bases are the
**four** paths the engine composes from its home directory, and that is the
whole set; `KIRO_HOME` still has zero occurrences in the engine bundle.

**One part is still only observed.** Which composition the _native_ layer
applies to `KIRO_HOME` is unresolved: the resolver above treats it as the
`.kiro` directory, but a help string in the same binary describes a session root
as defaulting to `KIRO_HOME/.kiro/sessions`, the opposite composition. A help
string is documentation, not a code path, and a string table does not reveal how
a value gets joined. It does not disturb the conclusion — either way `KIRO_HOME`
never reaches the engine and `HOME` always does — but do not quote one
composition for "the native layer" as though it were established.

**And do not redirect `XDG_DATA_HOME` for isolation.** It is a different lever
with a worse failure mode. The credential database is a single `data.sqlite3`
under `$XDG_DATA_HOME/kiro-cli/`, so a redirect produces an **empty** one, and
the response to no cached token is a **device-code browser login** — an
interactive prompt, not an error — so an unattended run hangs where it should
fail. The extracted engine bundles and the bundled Node, Bun and TUI artifacts
live under that same directory, so a redirect also hides the engine from its own
launcher. Leave it real. The price is a precondition, not a bug: isolation
cannot run on a machine that has never logged in.

**Where the evidence is:** every count above is re-asserted by
`harness/self-test-corrections.sh`, which reads the engine bundle and the client
binary only and refuses rather than passing when a positive control reads zero.
`harness/lib.sh` carries the same conclusion as an operational note.

**Lesson:** an isolation lever that silently removes a search path is
indistinguishable from a missing feature. State what an isolation mechanism is
expected to _cover_ before trusting a negative result obtained under it. And
when a question is recorded as unanswerable, record **which artifact** it was
unanswerable from — this one was unanswerable from the engine, was never put to
the client, and stayed open for that reason alone.

---

## C-2 — A symlinked hook file is skipped with no warning

**Belief:** delivery mechanism is irrelevant; a hook file is a hook file.

**Reality:** the directory reader classifies a symlink as its own kind, and the
loader keeps only entries typed as plain files. A symlinked hook is **silently
absent** — no warning, no log line, no error.

**How it presented:** as C-1. A declaratively-managed hook delivered as a store
symlink "did not load", which read as _global hooks are broken_ rather than
_this file is invisible_.

**Why it matters:** C-1 and C-2 are two independent causes of one symptom, which
is why the wrong conclusion survived a re-confirmation. Fixing either alone
would have left the other still producing the failure.

**Lesson:** **hook files must be real regular files.** And when two plausible
causes can produce the same silence, a probe that removes only one of them
proves nothing.

---

## C-3 — "Zero hits" was an unsafe way to assert an absence

**Belief:** searching a bundle for two exact identifiers and finding zero
establishes that no such capability exists.

**Reality:** the conclusion happened to hold, but the _method_ was unsound.
Exact spellings returned zero while several near-spellings returned non-zero —
differing in internal capitalization — all of them transcript payload schemas,
an activity-map value, and a permission-request flag rather than the capability
being sought.

**How it presented:** it did not present as a failure at all. It presented as a
clean confirmation, which is worse — a future re-run of the same naive search,
after any rename, would report a **removal that never happened**.

**Lesson:** **every asserted absence needs named positive controls** — strings
confirmed present by the same method — so "gone" can be distinguished from "the
artifact moved and the search no longer parses it". Search for the _concept_
with several spellings, not one identifier.

---

## C-4 — "All of the machinery lives in the new engine" was half true

**Belief:** the Rust CLI binaries are a thin client; all hook and workflow
machinery lives in the JS agent bundle.

**Reality:** the **workflow** half holds — zero workflow tool names across every
ELF binary. The **hook** half is wrong: a chat binary carries a complete
_previous-generation_ hook engine, including wire document types, action
variants, trigger variants, and error strings about blocked tool execution.

**How it presented:** a tidy generalization from one true observation. Because
the workflow search was genuinely empty, the hook conclusion inherited unearned
confidence.

**Reconciliation:** it is not a contradiction but a **two-engine split** — the
older hook engine in the native binary, the newer one in the JS bundle. The
correct statement names which engine, not which language.

**Lesson:** when two searches are bundled into one claim, report them
separately. A generalization across a boundary you have not tested is the
cheapest way to publish a false negative.

---

## C-5 — "The subprocess environment is empty"

**Belief:** hook commands run with no inherited environment, because the spawn
call passes an empty environment object.

**Reality:** the process runner merges the parent environment underneath —
`{ ...process.env, ...opts.env }` — so a hook **inherits the agent's entire
environment** and merely gains no hook-specific variables.

**How it presented:** the spawn site reads unambiguously as `env: {}`, and there
is even a shipped comment explaining the intent. The override happens one layer
down.

**Lesson:** a value at a call site is not the value at the syscall. Follow a
configuration object to its consumer before describing its effect — especially
when the call site carries a comment that sounds authoritative.

---

## C-6 — "First branch to complete wins" was assumed to be non-destructive

**Belief (working hypothesis, nearly acted on):** a first-completion join could
resume the caller while its remaining branches kept running — which would have
made a root-driven work drain possible.

**Reality:** the first-completion join **aborts every sibling** on the first
success. Vendor steering states it outright, and the scheduler aborts each
sibling's cancellation token.

**How it presented:** the tool description lists the join policy values and says
nothing about sibling fate. "First to complete wins" reads as _selection_, not
_cancellation_.

**Why it mattered:** an architecture was almost built on first-completion
resume. It would have destroyed in-flight work on every iteration, and the
symptom — items silently unfinished — is exactly the failure a work queue is
meant to prevent.

**Lesson:** for any join or race primitive, **the disposition of the losers is
the detail that carries the weight**, and it is the detail most often omitted
from documentation. Never infer it. This lesson was then under-applied to the
_other_ policies in the same enum — see C-15.

---

## C-7 — A validator that rejects "both" does not also reject "neither"

**Belief:** a node requiring exactly one of two mutually exclusive fields
rejects both supplying both _and_ supplying neither.

**Reality:** only the "both" case is enforced. The schema refinement expresses
_at most_ one, and the validator's message concerns defining both. **Neither is
structurally accepted** — producing a node with no termination condition at all.

**How it presented:** documentation says "exactly one", which sounds like a
bidirectional constraint. The permissive direction is the dangerous one: a loop
with no stop condition is accepted at authoring time.

**Lesson:** read "exactly one" as two separate claims and test both. The
under-constrained direction rarely errors — it just does something unbounded
later.

---

## C-8 — A "pause on exhaustion" option that cannot be resumed

**Belief:** pausing on iteration exhaustion is the safe choice, because a paused
run can be inspected and continued.

**Reality:** resuming grants **no further iterations** — every slot is already
spent, so it re-pauses immediately — and a paused run **cannot be retried**,
since retry applies only to terminated runs. The only ways forward are replacing
the remaining plan or cancelling and restarting from the beginning.

**How it presented:** as the conservative option among abort / continue / pause.
The documentation does describe this, which makes it a _reading_ failure rather
than a discovery one — the trap is that the safe-sounding name overrides the
paragraph.

**Lesson:** prefer the option whose failure is _loud and terminal_ over one
whose failure is a state you cannot leave. Read the semantics of the reassuring
default.

---

## C-9 — Long-lived workers, a design that looked right

**Belief (rejected design):** the natural way to drain a queue without barriers
is long-lived workers that each claim and process many items — a classic
work-stealing pool.

**Reality:** a worker accumulating enough context to cross its compaction
threshold triggers a compaction that **truncates its parent's stored history**.
The failure is data loss in the _caller_, not degradation in the worker.

**How it presented:** the design is correct in every respect that a throughput
analysis examines. Nothing about queue mechanics, fairness, or slot utilization
reveals the problem — it is a context-lifecycle interaction two layers away.

**Lesson:** worker lifetime is a **correctness** parameter, not only a
performance one. Recorded here rather than fixture-tested on purpose:
reproducing it destroys a session's history, and a code read plus an upstream
report is sufficient evidence.

---

## C-10 — "Subagents cannot recurse" was a role fact mistaken for an engine fact

**Belief:** the engine forbids a subagent from spawning a further subagent;
fan-out must be flat.

**Reality:** the engine supports nesting to a documented depth, with a counter
and an explicit depth-exceeded error, and nested dispatches are observable in
real transcripts. What is true is narrower: the **default role holds no
delegation tool**, so an unmodified subagent cannot nest.

**How it presented:** every attempt failed identically, which reads as a
platform prohibition rather than a missing grant. A public issue reporting
nesting failure appeared to corroborate it — but that issue is filed against a
_different product surface_, so it never evidenced this engine at all.

**Lesson:** distinguish _"the engine forbids it"_ from _"the default
configuration does not grant it"_. And check that a corroborating report is
actually about the thing you are testing — an issue against a sibling product is
not evidence, and it is the most convincing kind of non-evidence.

---

## C-11 — Documented capability with no implementation behind it

**Belief:** a feature flag whose own documentation says it can be turned on
locally through an environment variable can be turned on that way.

**Reality:** the client does read an enabled-features environment variable, and
its shipped catalog contains an entry whose own description says to enable it
that way — but **that catalog entry has no consumer**. The only feature checks
are unrelated literals. The vendor's own instruction is **inert**.

**How it presented:** as a documented, sanctioned door. Following it produces no
error and no effect, which is the hardest failure to diagnose — nothing is
broken, nothing happens.

**Lesson:** a documented enable path is a claim, not a mechanism. Trace the flag
to a **consumer** before believing it, and treat "documented but unconsumed" as
a distinct state from both "supported" and "absent".

**Update, 2026-07-30 (kiro-cli 2.15.2):** the door opened. The flag now has two
consumers and a row in the table that turns a feature into a wire setting, so
the vendor's instruction works and the entry is no longer inert. The negative
stands as **history, not as current behavior** — and it is more useful now than
when it was written, because it dates the transition: "documented but
unconsumed" was a real state that lasted at least four releases and then quietly
ended, with no announcement and no change to the description that was already
promising it. Re-check a decoy before building around its absence; see the
2.15.2 section of `drift-ledger.md`.

---

## C-12 — A closed issue whose defect is still live

**Belief:** an open issue tracks a live defect; a closed one is resolved.

**Reality:** one report was **auto-closed as a duplicate by a similarity bot**
at a partial-match threshold and folded into a related-but-not-identical issue.
The defect is unfixed; its report is gone.

**How it presented:** as a fixed problem. Filtering an issue list by state hides
it entirely.

**Lesson:** when a report closes as a duplicate, verify the target actually
covers it — bot-driven deduplication produces closed issues with live defects,
and status alone becomes unreliable as evidence.

---

## C-13 — Counting without a denominator, and counting a moving corpus

**Belief:** a count of zero occurrences in a body of transcripts establishes
absence.

**Reality:** two separate problems. A zero is meaningless without a
**denominator** proving the event family is recorded in those files at all —
otherwise "absent" and "not instrumented" are indistinguishable. And the corpus
is **live**: totals moved during capture because a session was appending, so
every count is a timestamped snapshot rather than a fact.

**How it presented:** a clean zero, in a large sample, feeling conclusive.

**Lesson:** publish absences as a ratio against a positive control in the same
files, and stamp every measurement over live state with when it was taken. A
count that cannot drift is a count you have not understood.

---

## C-14 — The display collapses the call graph

**Belief:** the interactive view can be used to confirm how deep a dispatch tree
went.

**Reality:** completed dispatch nodes collapse into a summary counting only
**direct** children, so a grandchild appears to have been spawned by the root.

**How it presented:** as visual confirmation of a flat fan-out — which is
precisely the wrong conclusion, and it agreed with the mistaken belief in C-10.

**Lesson:** verify structure from transcripts, never from the display. When an
observation _agrees_ with a belief you already hold, that is when to check the
instrument.

---

## C-15 — Two 64-hex hashes side by side, and the wrong one looks right

_Recorded 2026-07-30, during the 2.15.2 re-verification._

**Belief:** the hash that names an engine bundle's directory could be read off
the shipped binary by finding a 64-hex string near the extraction machinery.

**Reality:** the binary interns **four** such hashes — one per embedded asset —
and the one sitting immediately beside the phrase about extracting the runtime
belongs to the **runtime**, not the bundle. The bundle's own hash lives in a
different string neighborhood entirely. Worse, the directory suffix is the hash
of the **compressed** archive, not of its contents, so hashing the unpacked tree
produces a plausible-looking value that matches nothing.

**How it presented:** as a clean single hit in exactly the expected place, with
the right shape and the right length. Nothing about it looked like a guess.

**Why it fooled us:** the wrong hash is adjacent to text that names the
extraction, so proximity — normally the cheapest attribution method in this
bundle — pointed straight at it. It took a **cross-version** check to break the
tie: the runtime hash is byte-identical in the previous release, and the bundle
hash is not.

**Lesson:** when several values of the same shape sit near the same machinery,
proximity stops being evidence. Separate them by a dimension the artifact cannot
fake — here, whether the value changes between two releases — and confirm the
scheme by reproducing a value you **already know**, rather than by checking that
the one you derived looks reasonable.

---

## C-16 — The recorded tooling was no longer the tooling

_Recorded 2026-07-30, during the 2.15.2 re-verification._

**Belief:** the search tools named in every record preamble are what a replay
will actually run — in particular a search tool whose occurrence-counting flags
behave one way, which the preambles document explicitly.

**Reality:** those tools are on no search path on this machine any more — not
the login shell, not the development shell, not the user profile. The
replacements are the conventional implementations, in which the documented
counting flag counts **lines** rather than occurrences: the exact inversion the
preambles warn about, pointing the other way.

**How it presented:** it did not present at all. Every recorded count still
reproduced, because the corpus had already standardized on a counting form that
is unambiguous under both implementations. The discrepancy was only visible by
checking the tool versions on purpose.

**Why it matters anyway:** the records reproduce, but the **advice** in their
preambles is now backwards, and a reader who follows it will take the shortcut
it appears to license and silently measure the wrong thing. A convention that
survives a tooling change and a note that survives one are different questions.

**Lesson:** a record's environment is part of its claim. Stamp what you actually
ran with, re-check it on re-verification, and prefer the form that is correct
under every implementation over the form that is correct under yours — then the
tooling can move without taking the findings with it.
||||||| parent of 062a0591 (docs(kiro-primitives): settle C-1's mechanism and carry the joinPolicy trap)
## C-17 — "all" was picked as the safe join policy because C-6 had been learned, and it aborts siblings too

**Belief:** having rejected the first-completion policy for cancelling its
siblings (C-6), `all` is the safe choice — it is "just the final join", and it
waits for every branch.

**Reality:** `all` aborts every sibling the moment one branch settles **failed
or aborted** — not merely on failure, and only the all-succeed path waits.
`allSettled` is the one policy that structurally _cannot_ abort a sibling: it is
the only join function the scheduler never hands the branch controllers to, so
it has nothing to abort. It still reports the parallel node failed; it simply
lets every branch finish first.

**How it presented:** as the conservative option, and specifically as the option
chosen _because_ the first-completion trap had already been learned. The design
named `all` with the reasoning written out, so the reasoning read as diligence
rather than as an untested assumption — the strongest disguise available, since
a choice that cites a real prior finding does not look like a guess. Worse, the
refuting sentence was **already quoted in this corpus's own captured output**: a
bundled agent's steering says "`all`: all branches must succeed. First failure
aborts siblings", and the record carrying that quote went on, a hundred lines
later, to conclude that `all` was the only safe drain shape. Evidence and
contradiction sat in one file.

**Why it matters:** for a drain, one poisoned work item would cancel every other
branch — items silently unfinished, which is the exact failure a work queue
exists to prevent. It is C-6's hazard on a different trigger, and it caught a
design that had already routed _around_ C-6.

**Where the sentence lives:** each of the three sentences describing sibling
fate occurs exactly **once** in the 20.8 MB engine bundle, all three inside one
bundled agent's steering — none of them in the tool description a caller reads
while designing against the contract, which lists the three values and says
nothing about the losers. The field name itself occurs **14** times, which is
the denominator: fourteen mentions, three explanations, zero of them where the
contract is read.

**Where the evidence is:** unusually for this file, the mechanism here is
executed rather than only recorded — `records/workflow-surface.md`
(R-workflow-5, second correction) carries the replayable windows and counts, and
`harness/self-test-corrections.sh` re-asserts them and refuses on a zero
control.

**Lesson:** for a join primitive, enumerate the disposition of the losers on
**every** exit path, not just the one the name describes. Learning that one
policy cancels does not tell you which of the others also does — and a negative
you have already recorded protects only the specific trigger you recorded it
against.

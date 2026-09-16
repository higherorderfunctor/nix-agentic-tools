# Review artifact provenance

## September 15 DSL and contract revision

The user rejected the previous Gate 2 authoring presentation. The current
[review landing page](../README.md) links the rewritten, self-contained
[tutorial](../tutorial-dsl.md), separate [setup](../setup.md), synchronized
[interface](../interface.md) and
[scope reconciliation](../scope-reconciliation.md). The new `s` and `c`
namespaces remain proposed. The
[authoring prototype](../authoring-prototype/evidence.md) provides bounded
lowering and helper evidence; it does not install semantic APIs or change
Scribe.

Separate Astra/high workers revised the DSL, contracts and documentation using
allowlisted inputs. An independent Astra/high review replayed the evidence and
added counterexamples; the corrected prototype retains the review controls. The
coordinator's public-source reconnaissance used Astra/medium. The same context
boundaries described below apply. No worker received the coordinator's
scratchpad or repository-specific grammar, semantics or spec/plan corpus.

The earlier freezes below continue to describe their historical inputs. They do
not prove current contracts, semantic types, default providers or atomic
batches. Production implementation and gate progression still require the user's
review.

The [independent final review](dsl-review.md) resolves six findings and retains
its exact reviewed input hashes. The [publication map](dsl-publication.json)
records producer and delivered bytes, including link relocation and subsequent
Nix lint substitutions. [Publication replay](dsl-publication-checks.json) proves
identical evaluated values after those substitutions; the separate
[snippet checks](dsl-snippet-checks.json) cover five complete Nix expressions
and the standalone identity script. None establishes Scribe integration.

## Consumer walkthrough revision

The 2026-09-14 review revision replaces the entry README with a self-contained
consumer walkthrough. The original README from commit `46d20688` is retained as
historical [recommendation.md](../recommendation.md); the September 15 revision
adds an explicit supersession notice above its original content. The freeze and
publication records below describe that original review, not unchanged bytes for
subsequently revised files. The [revision map](consumer-readme-publication.json)
records these changes separately.

The [normalized authoring probe](../normalized-authoring/README.md) verifies the
existing grammar layer and identifies the missing Boolean document-field
contract. The walkthrough adds no implemented policy API. An isolated author and
[independent reviewer](consumer-readme-review.md) used the reviewed cases,
proposed contracts, neutral fixture and explicit public interface findings. The
coordinator alone read the old plan document supplied by the user and shared
only source-verified interface findings. The
[snippet checks](consumer-readme-checks.json) distinguish grammar evaluation and
standalone Python/Rego execution from syntax checks on proposed Nix interfaces.

## Original Gate 2 publication

The research worker froze two evidence revisions. Version 2 explicitly corrects
the selected Child traversal and protection controls, and verifies the combined
runner. Its correction note identifies the differences from version 1.

Files named `evidence-v1-sha256.json` and `evidence-v2-sha256.json` record the
producer's frozen bytes before repository formatting. The
[publication map](research-publication.json) records both producer and published
checksums. Markdown was reflowed and some JSON serialization changed; decoded
JSON values were checked for equality. Scripts and native inputs are
byte-identical to the frozen producer output. Three transcripts have only extra
terminal blank lines removed; the publication map identifies them.

The producer's `publication-allowlist.json` lists its research packet only.
Coordinator review/provenance documents and the separate interface proposals are
additional review artifacts. Downloaded dependency/source trees, build products,
and coordinator scratchpads are excluded from the tracked package.

The ideal workflow received reviewed requirements and the public toolchain,
without tooling research. The tools-informed workflow received the same contract
and the research, without the ideal output. Both froze before the comparison
workflow received them. Design and review workers used fresh Astra/high
contexts; mechanical audits and the runtime pairing probe used Astra/medium.
Read boundaries excluded the repository's existing grammar values, semantic
implementation and specification/plan corpus. These were context boundaries, not
a claim of hostile filesystem isolation.

The [interface publication map](interface-publication.json) records original and
published checksums. Publication edits relocate links, apply repository
formatting and Nix style fixes, and repair whitespace in the public-toolchain
brief. Frozen originals remain in the private session backup. Audit line
references refer to their frozen inputs, before publication formatting.
Alternative proposals and the original recommendation remain historical inputs.
The current [review landing page](../README.md) identifies the active proposal.

All interfaces and playbooks in this Gate 2 package remain proposals. Syntax
parsing and experimental capability results are separate from production Scribe
integration acceptance. Gate 3 requires the next human review.

# Review artifact provenance

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
Alternative proposals remain historical inputs; the recommendation is the review
candidate.

All interfaces and playbooks in this Gate 2 package remain proposals. Syntax
parsing and experimental capability results are separate from production Scribe
integration acceptance. Gate 3 requires the next human review.

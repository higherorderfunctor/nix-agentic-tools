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

All interfaces and playbooks in this Gate 2 package remain proposals. Syntax
parsing and experimental capability results are separate from production Scribe
integration acceptance. Gate 3 requires the next human review.

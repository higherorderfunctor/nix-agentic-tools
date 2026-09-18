# Independent review disposition

All four findings are corrected within the bounded Gate 2 prototype. The
readable constructor vocabulary and canonical reference lowering are unchanged.
No runtime integration, later gate or production authorization is implied.

| Finding                                          | Correction                                                                                                                                                                                        | Focused evidence                                                                                                                                                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1: nested visibility lost dependencies          | Recursively collect supported expression requirements; lift view bindings into predicate `inputs` and validity/singleton IDs into `after`. Shared views deduplicate; conflicts reject.            | Nested `anyOf`/`allOf` has the hierarchy input and validity dependency; disabling either or both rejects; intact dependencies accept. Original independent reproducer now rejects removal.                     |
| R2: malformed results accepted                   | Validate exact result/Finding keys, string identities/text, expected evaluation ID, typed lists, NodeRef subjects, integer locations and JSON-object evidence before aggregating.                 | Null lists, numeric IDs, scalar findings/causes, malformed subjects/locations/evidence, wrong finding rule and wrong evaluation reject. Structured satisfied/violated/error/blocked controls still pass.       |
| R3: inconsistent contextual resolution           | Shared explicit input prerequisite resolves full model-qualified references and rejects duplicate NodeRefs/occurrence IDs and absent owners/targets. Separate target entry selection is retained. | Both entries error on wrong-model/missing owners or targets and duplicates; other-grammar owner is unselected while other-grammar target violates. Earlier findings survive later resolution/duplicate errors. |
| R4: required ID substituted for required meaning | Required definitions originally declaring the known native DAG contract must retain its all-role config, scope, candidate input and mandatory capabilities before and after edits.                | True-predicate replacement, narrowed config, before input, missing capability, wrong scope and invalid original reject; equivalent replacement and extra capability requirements accept.                       |

R2's concrete checker covers NodeRef findings and integer-coordinate locations
used by these local entries. It rejects unsupported shapes; it does not
establish a production general SourceRef or native-coordinate schema. The common
interface retains that broader surface. R3's shared prerequisite is an
identity/resolution check, not complete native snapshot validation. R4 is
selected by the original native DAG contract, not a special fixture ID;
unrelated required IDs still get presence checking and do not automatically
imply native semantics. Arbitrary custom-contract compatibility remains future
work.

The independent adversarial sources were copied unchanged and run against the
corrected output through isolated filesystem wiring. Python reports 13 passed,
zero failed; its supplied-forest path oracle still covers 162 combinations. Nix
reports both originally accepted bad compositions rejected, while the previously
passing singleton controls remain passing.

Publication adjustments are adopted: unused callbacks use `_self`, `_:` or
`{ elements, ... }` as appropriate without narrowing the supplied callback
argument shape. The identity default example now labels `{ status; value; }` as
a payload fragment; the full proposed provider envelope also includes protocol
and request ID. Deadnix passes; no automatic deadnix edit was used.

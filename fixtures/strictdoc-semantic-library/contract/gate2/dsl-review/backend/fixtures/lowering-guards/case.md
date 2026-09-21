Situation: nine models that exist to be lowered, not evaluated. Seven are
refused during lowering and two are accepted. None carries a candidate or a
`results.json`, so the conformance harness never treats this directory as a
fixture; `tests/test_lowering_guards.py` lowers each one and reads the message.

Situation: a family that authors a model ships a `bundle.json` beside it, and
`tests/test_variant_bundle.py` compares the two. These models are named after
what they probe rather than `model.nix`, so that comparison never claims one of
them should have lowered.

Change: each model is whole and independent. The two accepted models are the
positive controls: without them a harness that could not lower anything at all
would report seven refusals and read as green.

Expected: `field-value-names-another-elements-field` is the blocking one. A
field constructor names a field; it does not say which element declares it.
Handing a NOTE check the TASK constructor for the same-titled field used to
lower clean, load clean, and violate on every NOTE forever, with no error
anywhere. The values are now checked against the choices the subject's own
element declares.

Expected: `field-value-owner-subject-field-the-owner-lacks` is refused because
an occurrences selector fixes the OWNER element. It used to load and then block
every occurrence, reporting a model configuration fault as an unevaluable
candidate. `field-value-target-subject-another-elements-field` is the accepted
counterpart: a target subject fixes no element, so the name resolves against the
model and an element lacking it blocks that one leaf at evaluation.

Expected: `field-value-integer-value` and `field-value-boolean-value` are
refused because a field value is a native string. The integer used to lower into
the bundle and be caught by the Python loader; the Boolean used to die on a Nix
coercion error naming no field.

Expected: `native-single-choice-field` and `native-tag-field` are refused
because only a native string field derives a semantic type. Both spellings used
to derive one from the native tag and emit `singleChoice` or `tag`, which every
backend refuses by that internal name.

Expected: `file-relation-declaration` is accepted. A File relation names a path,
so it declares no owned occurrence, carries no role and no direction, and
reaches the native grammar alone. It used to be refused by a message naming the
direction keyword space. `native-relation-of-an-unknown-kind` is the
counterweight: File is the one native key that is dropped, and every other key
still reaches that keyword space, so dropping the File case did not turn a typo
into silence.

Why: every refusal here is a model configuration fault that the author can see
and the candidate cannot cause. A fault reported at evaluation names a record,
which sends a reader to the corpus for a defect that is in the model.

provenance: gate 2 DSL review findings

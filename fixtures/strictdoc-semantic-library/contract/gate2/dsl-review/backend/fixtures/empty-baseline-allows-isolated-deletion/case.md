Situation: drawn base corpus; I0 is an old, isolated FOO record with no
relations and nothing pointing at it. The provider returns S0, the empty
complete snapshot (contract.md:526-528). Change: delete I0 from the final
candidate. Nine records remain; `created` stays empty, so no creation default
applies to anything. Expected: baseline-preserved satisfied (one model finding,
code `preserve`, baseline "baseline-empty", differences []); H-forest satisfied
(violations []); native-dag satisfied (cycles []). one-H-parent loses its I0
finding and keeps the other eight FOO records in candidate record order;
H.target-type is unchanged because I0 owned no occurrence. Envelope satisfied.
Why: "existence: true requires each baseline-listed record to survive"
(contract.md:344) and an empty snapshot lists none (contract.md:526-528);
deleting an isolated vertex removes no edge, so the forest and the native graph
stay valid (contract.md:243-244). Note: the envelope has no separate acquisition
or completeness field. Successful capture of a complete snapshot is recorded as
a non-null `baseline` identity plus the absence of an execution error
(contract.md:569-570, contract.md:523-525); "zero protected records" is recorded
as `differences: []`. provenance: E04

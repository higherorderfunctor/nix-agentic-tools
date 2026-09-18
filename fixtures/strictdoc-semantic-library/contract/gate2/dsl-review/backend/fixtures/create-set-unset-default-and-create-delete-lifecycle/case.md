Situation: the drawn base tree with the packet baseline S1 protecting I0.
Change: created = ["N0","N9"]. N0 survives in the final records as an isolated
FOO with no FLAG key, having been set and then unset inside the batch. N9
appears only in created and is absent from records. Expected: all eleven rules
satisfied and envelope satisfied. one-H-parent gains exactly one finding, N0 at
count 0 (10 findings); H.target-type is unchanged at 6. No envelope
field-validation finding exists for N0's absent required FLAG, because it is
filled once with ["false"], and no finding, subject, cause or error anywhere
names N9. Why: only the final batch state is evaluated, so the private set/unset
sequence cannot decide validity (contract.md:449-450); the fill happens after
all explicit batch edits, exactly once, before any validation
(contract.md:888-890); a created uid absent from the final records was deleted
and receives no default (contract.md:885-886); newness comes from the supplied
change set, not baseline membership (contract.md:886-888). Ambiguity: "exactly
once" and "no acquisition for a deleted uid" are not separately observable in a
single envelope — a redundant second fill of the same literal, and a fill
computed and then discarded for N9, both leave this envelope identical. What the
fixture does pin is that N0's absence yields no error finding and that N9 is
never a subject; a backend that errors on a created-but-deleted uid, or that
defaults old records, fails it.

provenance: DFT06

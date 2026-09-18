Situation: the drawn tree; the provider now yields the S1 snapshot
baseline-I0-closed-s1, protecting I0 with FLAG true, in place of S0. Change: the
drawn base candidate plus an R parent from F1a to F2a at occurrenceIndex 1, the
contract's own worked visibility case (contract.md:706). The protected record I0
is not edited: its FLAG stays false, exactly as in the base corpus, so the
preserve difference comes from the new baseline identity and not from an edit to
the protected record. Under S0's baseline-I0-open, which records I0 FLAG false,
this same candidate would satisfy preserve; that comparison arm is not
materialized here, so the fixture shows the S1 outcome only. Expected: R.all
violated. Its target-type leaf is satisfied; its visible-target leaf is
violated, code closed-boundary, boundary F2. baseline-preserved violated, code
difference: I0 FLAG before true, after false. The other nine rules stay
satisfied. Envelope violated. Why: contract.md:311 forbids that departure;
contract.md:245 and contract.md:638 fix the preserve verdict and its evidence
shape. Scope note: the R addition is independent of the provider swap. Its
closed-boundary violation reads no baseline input, so the swap does not
recompute it; this fixture therefore carries two independent violations and only
the preserve one is sensitive to the baseline identity.

provenance: X06 Mixed: no bundle or policy identity in results.json; policy arm
not shown.

- Situation: the same batch as
  delete-target-and-referencing-declarations-in-one-batch, stopped short.
- Change: delete F2b but keep F1a's R occurrence (index 1) targeting F2b.
- Expected envelope finding: one error, code unresolved-target, on that
  occurrence, predicatePath and kind null (contract.md:621).
- Expected R.all: blocked, both leaves blocked with unresolved-target, causes
  ["/findings/0"]. native-dag blocked, same cause (contract.md:256).
- Expected H-forest satisfied (R is not an in-view edge, contract.md:296);
  one-H-parent satisfied ("Counts do not need target resolution", 465).
- Why: contract.md:460 emits that input finding and blocks every rule whose
  evaluation needs the resolution; the envelope is therefore error.
- provenance: A03

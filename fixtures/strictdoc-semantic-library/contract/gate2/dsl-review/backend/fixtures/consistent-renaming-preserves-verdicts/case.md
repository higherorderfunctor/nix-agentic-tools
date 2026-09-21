Situation: the drawn tree, every uid renamed (alpha/beta/gamma/omega); no core
uid survives. Element, role and field names stay FOO/H/FLAG: one fixed bundle is
supplied and a fixture directory has no bundle slot. Change: the wrong-element
target rejection mirrored on the renamed tree. alpha-1-leaf gains R parent to
omega-other, the BAZ record, at occurrenceIndex 1. Expected: R.all blocked. Its
target-type leaf is violated, expected FOO actual BAZ. Its visible-target leaf
is blocked, code input: omega-other is no H vertex. The other ten rules stay
satisfied, on renamed uids only. Why: contract.md:239 and contract.md:302 with
contract.md:814 decide the two leaves; contract.md:227 and contract.md:589 make
the rule blocked. Catalogue divergence: the mirrored catalogue row
(scenarios.md:36) expects the rejection to come from a target-type rule, but
this bundle reaches target-type only inside the composed R.all, and a blocked
visible-target child makes the whole expression blocked, so the rule status is
blocked and not violated (contract.md:227, contract.md:589). The wrong-element
violation is still carried by the target-type leaf, and the envelope still
refuses the candidate, because acceptance requires a satisfied envelope
(contract.md:665). The fixture follows the contract.

provenance: X02 Mixed: no renamed bundle, so the mapped-verdict comparison is
unexercised.

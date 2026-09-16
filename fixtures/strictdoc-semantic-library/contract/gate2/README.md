# Review the revised semantic DSL

`g` is the existing `grammar.dsl`. `s` is the proposed semantic schema, type and
reference layer. `c` is a **new proposed constraint DSL**, not a Nix builtin or
a renamed `p` interface.

Start with [the seven DSL lessons](tutorial-dsl.md): declarations, small models
and concrete expected diagnostics. Then read [setup](setup.md) for current
native commands, proposed integration, creation defaults and atomic batches. The
complete sources are [recommended.nix](recommended.nix),
[composition.nix](composition.nix), [native-tailoring.nix](native-tailoring.nix)
and [field-alternative.nix](field-alternative.nix).

The [evaluated public shape](authoring-prototype/public-shape.md) and
[design](authoring-prototype/design.md) explain the bounded prototype. Supplied
results report 57 Nix controls and 110 synthetic Python helper controls. These
establish lowering/check/render and specific local helper behavior, not the
common process invocation or real Scribe enforcement. The unchanged independent
review scripts also replayed successfully: 13/13 Python checks, including 162
supplied-forest path combinations.
[Setup's evidence table](setup.md#what-the-evidence-establishes) states the
limits.

[Reviewed requirements](reviewed-requirements.md),
[scope reconciliation](scope-reconciliation.md) and [interface](interface.md)
govern the proposal. The [reference model](../model.md),
[scenarios](../scenarios.md), [playbooks](playbooks.md) and
[closing plan](closing-plan.md) preserve the controls and later obligations. The
[historical recommendation](recommendation.md) retains backend research
provenance.

Exact names remain reviewable. The remaining choices concern vocabulary,
identity escaping and generic predicate exposure. **Gate 2 is not declared
passable; this packet does not advance gates or authorize production
implementation.**

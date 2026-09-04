# Semantics model shape

`model.json` is the hand-written transcription of the semantics model. Its
top-level value is an object with schema `sdoc-semantics-model/1`, a
`model_version`, and named collections in presentation order: `lifecycles`,
`actors`, `commands`, `events`, `operations`, `gates`, `relation_contracts`,
`checkpoints`, `milestones`, `flows`, and `rules`. Every collection is a list;
order is data and must not be recovered from object keys.

A lifecycle has a `name`, tagged `subject`, ordered `states`, `initial` and
`terminal` state names, and `transitions`. A subject is one of:

- `{ "kind": "field", "field": "..." }`, for every grammar element carrying the
  field;
- `{ "kind": "element", "tag": "...", "field": "..." }`, for one element tag and
  field; or
- `{ "kind": "role", "role": "...", "field": "..." }`, for a relation role and
  field.

States have `name`, `label`, and `note`. Transitions have `trigger`, `from`,
`to`, `gates`, `writes`, `emits`, `rule_text`, and `settled`. The remaining
collections are the vocabulary for the interpreter: references are names and are
validated when the document is loaded. Top-level rules have `id`, `text`,
`kind`, `settled`, and `cites`. The compatibility payload groups a rule under a
lifecycle when its id begins with that lifecycle's normalized name (`_` becomes
`-`) plus `-`; rules without that prefix remain model-wide rules only.

This first document deliberately has no gates, operations, events, or other
cross-lifecycle entries. The three lifecycle declarations are a transcription of
the former Python machines, including their open rules; shaping those questions
belongs to the operator.

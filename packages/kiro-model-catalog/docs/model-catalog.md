# Kiro public model catalog

> **Last verified:** 2026-11-11 — suggestions come from the public comparison
> table; normalization preserves numeric dots and accepts new providers.

`cli.native.settings.chat.defaultModel` reads the committed `models` fact
through `lib.extracted` as a soft enum. Any string remains accepted across the
library, Home Manager and devenv. Suggestions describe the public catalog, not
account entitlements.

The independent `kiro-model-catalog` recipe pins
[Kiro's public model documentation](https://kiro.dev/docs/models.md) through
`lib/web-docs.mkSnapshot`. Its build parses that fixed-output source offline;
evaluation reads committed facts. The `kiro-cli` release and binary extractor do
not supply the catalog.

The parser reads the `Model` column in the unique `Quick comparison` table,
strips bold and trailing superscript annotations, lowercases display names and
replaces spaces with hyphens. Numeric dots remain intact. Provider names are
data: do not maintain a provider allowlist, rewrite versions or supplement the
table with historical recipe IDs.

Missing or ambiguous tables, malformed rows, residual markup, unsupported
punctuation, dots outside numeric versions, duplicate names and normalization
collisions fail at extraction. Auto and at least one concrete model are
required. A malformed or unavailable source fails the isolated catalog update
until the source or parser is repaired. The extracted-facts check verifies the
pinned source against the committed suggestions.

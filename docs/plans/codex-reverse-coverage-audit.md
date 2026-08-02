# Codex 0.146.0 reverse extraction-to-Nix coverage audit

> Last verified: 2026-08-02 against `pkgs.ai.chatgpt-codex` 0.146.0, its
> committed extracted sidecar, and the current official OpenAI Codex manual
> (commit pending — CX-013).

## Purpose

The generated `overlays/chatgpt-codex-extracted.json` answers “what does the
pinned binary expose?” It did not previously answer the reverse question: “where
does every extracted fact go in Nix?” A green extraction drift check could
therefore coexist with an unreviewed new command or flag, and two closed CLI
enums were still duplicated manually in `mkCodex.nix`.

CX-013 adds a human-authored disposition in
`packages/chatgpt-codex/lib/extractedCoverage.nix` and a blocking
`chatgpt-codex-coverage` flake check. The generated sidecar remains upstream
fact; the coverage file records local ownership judgment. Update automation may
regenerate the former, but it must never rewrite the latter.

## Audited snapshot

| Extracted category    | Count | Coverage rule                                                                                                                                      |
| --------------------- | ----: | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Recursive commands    |    67 | Every command path occurs exactly once in a reviewed disposition category                                                                          |
| Canonical long flags  |    83 | Every distinct first flag name occurs exactly once; aliases stay attached to that record as invocation syntax                                      |
| Feature rows          |   100 | Every record field and every observed maturity is covered; stable names become typed dynamically, while other names use the boolean freeform table |
| Bundled model records |     8 | Every model field is classified; reasoning levels feed typed enums, while slugs remain non-enforcing hints                                         |
| Config-key rows       |     0 | Both unsupported extraction seams are required to remain empty until newly extracted keys receive explicit dispositions                            |

The gate also locks the command-record fields, flag-record fields, provenance
fields, and the invariant that `cli.globalFlags` is the root command’s flag set.
Counts are documentation, not assertions; exact set comparison is the assertion
and reports both missing and stale dispositions.

## Command and flag outcomes

Commands are partitioned by ownership rather than mechanically turned into Nix
options:

- Declarative configuration writers (`features enable/disable`,
  `mcp add/remove`) have direct settings or MCP materializers. Nix emits
  destination state and does not invoke the mutable CLI writer.
- Developer/protocol tooling (app server, exec server, MCP server, schema/type
  generators, debug commands, and completion output) remains callable from the
  installed package. It has no durable module state.
- Credentials, cloud jobs, conversation archives, remote-control processes, and
  plugin/marketplace operations remain native runtime state.
- Interactive, review, exec, sandbox, and inspection commands are task/session
  operations. Persisting them would confuse invocation operands with defaults.
- `codex update` is deliberately inert under Nix ownership; the overlay and
  repository update pipeline own the immutable package version.

Flags use the same boundary. Durable semantics map to typed/freeform settings,
profiles, permission profiles, feature toggles, or MCP records. Protocol
transport flags, runtime-auth/plugin inputs, task selection, IO, formatting, and
dangerous one-shot bypasses stay at invocation scope. Canonical names are the
classification identity because aliases are alternate spellings of the same Clap
record. Context-overloaded names such as `--env` remain session-only rather than
receiving a false universal configuration meaning.

## Extracted data consumed by options

| Extracted fact                          | Nix use                                                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--ask-for-approval.acceptedValues`     | Typed preset branch of `ai.codex.settings.approval_policy`; now read directly instead of duplicating the three values                                        |
| `--sandbox.acceptedValues`              | Typed `ai.codex.settings.sandbox_mode`; now read directly instead of duplicating the three values                                                            |
| Stable feature names                    | Generated typed children of `ai.codex.settings.features`                                                                                                     |
| Non-stable feature names                | Accepted through that table’s boolean freeform type; deprecated/removed names are never promoted to advertised options                                       |
| Feature defaults                        | Provenance only; an absent Nix leaf deliberately lets the pinned binary choose its native default                                                            |
| Union of model reasoning levels         | Typed `model_reasoning_effort` and `agents.default_subagent_reasoning_effort` enums                                                                          |
| Model slugs/display/default effort      | Non-enforcing provenance: availability varies by account/provider/rollout, presentation is not config, and omission should preserve the model-native default |
| Empty config-key extraction collections | Fail-closed sentinel. Manual-documented config is already represented by typed/freeform TOML and the CX-012 expose/defer ledger                              |

No further materializer was justified. The reverse audit confirms that the
remaining extracted CLI surface is operational, runtime-owned, dynamically
covered, or already represented by an existing declarative escape hatch.

## Why this is a separate check

`chatgpt-codex-extracted` proves byte-for-semantic equality between the packaged
binary probe and the committed generated JSON. It cannot prove that the module
understands a new fact: update automation intentionally regenerates the JSON, so
comparing generated output to generated output can bless a newly exposed surface
with no human decision.

`chatgpt-codex-coverage` compares that generated vocabulary to a curated,
categorical partition. It fails on:

- a new, removed, duplicated, or stale command/flag disposition;
- a changed command, flag, feature, model, or provenance record shape;
- a new feature maturity without a declared policy;
- divergence between root and exported global flags; or
- any newly populated config-key extraction seam.

Dynamic categories are policy-covered on purpose. A newly bundled model does not
require a frozen slug-list edit because `model` must stay a string; a newly
stable feature becomes typed automatically because the factory derives stable
names from the sidecar. New schemas, fields, maturities, commands, and flags do
require review because they can change the ownership decision.

## Official sources

- [Configuration reference](https://developers.openai.com/codex/config-reference)
- [CLI command reference](https://developers.openai.com/codex/cli/reference)
- [Advanced configuration](https://developers.openai.com/codex/config-advanced)
- [Model selection](https://developers.openai.com/codex/models)

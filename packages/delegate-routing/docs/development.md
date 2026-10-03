# Delegate routing package

> **Last verified:** 2026-10-03 — portable families and runtime selectors
> replace pinned model versions; structured techniques describe delegation
> controls.

`ai.programs.delegate-routing.families` is the portable decision table, keyed by
vendor and family. Each family has a capability tier, task and effort guidance,
and a required normalized live-model pattern. Package fields use `mkDefault`, so
consumers can override one field or add a family without replacing the table.
`lib/families.nix` carries the eight package families; it contains no concrete
model versions.

Each runtime chooses families through
`ai.<runtime>.programs.delegate-routing.models`. Selectors are alternatives;
within a selector every non-empty field must match the vendor, tier and family
name. Claude defaults to Anthropic, Codex to OpenAI, and Kiro to no selection.
Empty selectors, and selectors naming a vendor, tier or family that is not
configured, fail assertions. An enabled program on an enabled runtime must
select at least one family. That program's `extraRuntimes` and
`manualExternalDelegates` targets also need a family selection, even when a
target runtime or program is disabled.

Resolve a concrete model at launch time: introspect the runtime's live list,
choose its newest model matching the family's pattern, and use that runtime's
spelling. Claude's interactive tools take aliases such as `opus`.

`extraRuntimes` adds automatic external candidates and requires the target
runtime to be enabled. `manualExternalDelegates` adds instructions for explicit
user requests without requiring runtime enable. Manual-only wins if a target
occurs in both lists. Selected families appear once per tier with all applicable
native and external reaches. A cross-vendor review sentence appears only when
automatic candidates span multiple vendors.

`ai.<runtime>.programs.delegate-routing.techniques` is a keyed set of workflow,
subagent, external, introspect and usage nodes. Delegate nodes declare whether
they pin model and effort and where they are available: interactive, headless or
ACP. Assertions require both pin fields to be non-null exactly for delegate
kinds, and a command for every external node. Each package field uses
`mkDefault`; consumers can replace fields, add nodes or disable individual
nodes. External and manual runtime sections include only external, introspect
and usage nodes. Codex has no workflow node. Shared table rendering escapes
cells once for families and techniques.

Portable `rules` and `procedure` use `lib.ai.types.optionalTextSource` with
enabled package `defaultContent`. Set `text` or `source` to replace either, or
`enable = false` to omit it. Rules lead the skill; the procedure follows its
runtime techniques. The procedure includes review routing and requires the judge
to review for subtraction.

Both Home Manager and devenv import `modules/common.nix`, which declares this
option surface and imports `mkSkillPackageModule` once for Claude, Codex and
Kiro. Per-runtime program enable inherits portable enable through the same
null-as-inherit rule as the factory. Skills and router rules contribute to
per-runtime pools, never the portable pools. Runtime-only controls are not
declared at the portable scope.

The portable `whenToDelegate` entries are unchanged. Attribute names become
headings in the always-on router rule. Entries use `optionalTextSource`:
consumer content auto-enables an entry, while an explicit `enable = false` wins.
Package defaults use `lib/when-to-delegate.nix`'s `mkPreset` with exactly one
source or text; default-priority content stays dormant until enabled or
overridden. Consumer entries must NOT use `mkPreset`: normal-priority content is
what triggers auto-enable. Attribute renames merge under the new key and warn.
An empty consumer `text` value does not auto-enable a default-disabled entry.
Required entries and optional entries enabled explicitly or by default must
resolve to non-empty `text` or a `source` path. Home Manager exposes warnings
through its module option; devenv uses `lib.warn` during assertion evaluation.

`fragments/skill-routing.md` is the short always-on stub. `router.nix` appends
enabled `whenToDelegate` entries. With no enabled entries it is byte-identical
to the stub. This repository enables the guidance and consumes it through
`dev/ai.nix`. Kiro is enabled with its own skill selecting Anthropic families,
and is also a manual-only external delegate for Claude. Copilot and Kimchi are
excluded from this program. The router is delivered in
`.claude/rules/delegate-routing-router.md` and inline in AGENTS.md for Codex and
Kiro; byte-identical contributions deduplicate. Keep model tables and harness
details in the generated skill.

The content package injects packaged usage helper paths into technique defaults.
The Claude helper carries curl and jq; the Codex helper carries timeout, jq and
Python, while the consumer supplies the Codex CLI. `mkSkill`, `render` and
`skills` use the same family, selector, technique and text inputs. Generated
skill trees use `lib.ai.generated` and the shared Markdown formatter; previews
read the built files. Package discovery supplies content, both backend modules
and the module checks.

## Preview skills

Run from the repository root. These commands print generated skills without
launching delegates.

```bash
nix eval --raw .#delegate-routing-content.skills.claude.text
nix eval --raw .#delegate-routing-content.skills.codex.text
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "kiro"; models.kiro = [{vendors = ["anthropic"];}]; }'
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "claude"; extraRuntimes = ["codex"]; manualExternalDelegates = ["kiro"]; models.kiro = [{vendors = ["anthropic"];}]; }'
```

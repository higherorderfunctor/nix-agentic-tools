# Delegate routing package

> **Last verified:** 2026-10-03 — model ids match the extracted catalogs; Kiro
> rows intersect the catalog, including Fable 5.1; sizing guidance follows
> rendered models.

`lib/models.nix` owns the model decisions and runtime ids. `lib/render.nix`
generates one skill per runtime: first-party candidates first within each tier,
then enabled external pools. Kiro candidates intersect the `models` array in
`packages/kiro-cli/extracted.json` at build time. The kiro-cli extractor
generates these ids from the public catalog; the skill still requires the live
list before a workflow pins an id because account availability differs. For
example, Fable 5.1 renders only when its `claude-fable-5.1` Kiro id is in the
catalog. A row carries a `kiro` id only when Kiro serves that exact version; a
model whose Kiro version lags gets no Kiro id. Manual external entries add
instructions, never candidate rows; manual-only wins if a consumer lists a
runtime in both external lists.

Both backends import `modules/common.nix`. It imports `mkSkillPackageModule`
once with all three supported runtimes. The factory passes `runtime` to its
`skills` and `rules` callbacks, so each skill uses that runtime's settings.
Runtime-only options extend the factory's program override submodule; external
pools and instruction overrides cannot be set at `ai.programs.delegate-routing`.
The portable `whenToDelegate` attribute set is the exception: each entry adds
always-on guidance under a heading taken from its attribute name. Entries use
`lib.ai.types.optionalTextSource`; consumer `text` or `source` automatically
enables an entry, while an explicit `enable = false` still wins. Packages must
declare presets with `lib/when-to-delegate.nix`'s `mkPreset`, passing exactly
one independent `source` path or `text` value. The constructor applies
`mkDefault` to the content so the preset stays dormant and consumer content can
replace it. A consumer definition on a preset key replaces its content and
enables it, just like a brand-new key. Consumer entries must NOT use `mkPreset`:
normal-priority content is what triggers auto-enable. Attribute-key renames live
in `lib/when-to-delegate-renames.nix`; old-key definitions merge into the new
key and warn until consumers update their configuration.

An empty consumer `text` value does not auto-enable a default-disabled entry.
Required entries and optional entries enabled explicitly or by default must
resolve to non-empty `text` or a `source` path.

Instruction presets live in `lib/presets.nix` and use
`lib.ai.types.optionalTextSource` with `enableDefault = true`. The presets pass
through the type's `defaultContent` argument, which contributes inner
`mkDefault` definitions while the enclosing option keeps an empty default. A
consumer who sets only `enable = true` therefore retains the package prose. The
source runtime's settings control its external launch even when its skill is
disabled: an enabled Codex CLI may still serve Claude delegates without
installing its own sizing skill. `settings.<block>.enable = false` omits an
instruction block; it does not remove models from the table. Disabling Kiro's
launch block also drops the manual-only purpose line that points at it. Set
`text` directly or use `source` to replace a block's package preset. The
consumer supplies the omitted instructions when needed. Kiro's default external
launch is manual-only and launches fixture probes with `--model auto`. Before
adding Kiro to `extraRuntimes`, override its `settings.launch.text` or `.source`
with instructions that apply the selected model and effort.

Usage helpers are packaged applications with their own runtime closures. The
Claude helper carries `curl` and `jq`; the Codex helper carries GNU `timeout`,
`jq` and Python 3. It deliberately does not carry the `codex` CLI, which comes
from the consumer's own runtime configuration. Both helpers read account limits
without launching a model turn. Their absolute store paths are embedded in the
skills without creating a dependency cycle. Skill derivations use
`lib.ai.generated` to format their Markdown with the shared Prettier defaults;
the preview functions read those built files.

`fragments/skill-routing.md` contains a one-sentence always-on stub under its
own heading. `router.nix` appends enabled `whenToDelegate` entries to that stub
and supplies the result to both the factory and repository projections. With no
enabled entries, the result is byte-identical to the source stub. `lib/rules.md`
holds the six rules; `lib/render.nix` places them at the top of each runtime's
skill, before the preamble. This repository consumes the rule like any project:
`dev/ai.nix` enables the program, which delivers it as Claude's
`.claude/rules/delegate-routing-router.md` and inline in AGENTS.md for Codex and
Kiro (their byte-identical contributions deduplicate). Copilot does not receive
it; the program supports Claude, Codex and Kiro. Keep model tables and harness
details in the generated skill.

Home Manager exposes generated diagnostics through its module-system `warnings`
option. Devenv does not declare that option, so the common module uses
`lib.warn` while evaluating its assertions as a portable fallback.

Content, HM/devenv modules and eval checks are discovered through the package
owner layout. The registry excludes this generated content package from release
updates. `checks/module-eval.nix` verifies both consumer backends, including
runtime-only options, manual access without enable, custom/disabled blocks and
the short stub. Its file checks realize the generated skill directories.

## Preview a runtime's skill

Run from the repository root. The Claude preview uses this repository's external
delegates; the Codex and Kiro previews use package defaults. Each command prints
the generated `SKILL.md` without launching a delegate.

Claude:

```bash
nix eval --raw .#delegate-routing-content.render --apply 'render: render { runtime = "claude"; extraRuntimes = ["codex"]; manualExternalDelegates = ["kiro"]; }'
```

Codex:

```bash
nix eval --raw .#delegate-routing-content.skills.codex.text
```

Kiro:

```bash
nix eval --raw .#delegate-routing-content.skills.kiro.text
```

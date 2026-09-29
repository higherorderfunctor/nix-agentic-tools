# The house prose style: prettier's options for Markdown (and YAML), defined
# ONCE. `lib/generated-style.nix` shares it between this repository's tracked
# files and the generated files `ai.*` delivers by default:
#
#   * treefmt.nix, as `programs.prettier.settings` (every tracked file).
#   * lib/generated.nix, as the `--config` of the Markdown and YAML defaults
#     under `ai.generated.formatter`.
#
# `always` (reflow prose to printWidth), NOT `preserve`, and the
# difference is load-bearing rather than cosmetic. Prettier treats an
# inline code span as an UNBREAKABLE token: reflowing moves an
# over-long span onto its own line and lets it overflow rather than
# splitting it, and it JOINS any span that already straddles a
# newline. So this setting makes `a `split\nspan`` structurally
# impossible, and checks/repository/formatting.nix turns that into a CI gate for
# free. Under `preserve` the same defect merely persists — measured
# at 369 spans across 66 files when this was flipped.
#
# That matters because these files are read as RAW markdown by agents
# out of `.claude/rules/`, `.github/instructions/`, and
# `.kiro/steering/`, never as rendered HTML. CommonMark does render a
# split span correctly in the general case (the newline becomes a
# space) — except where the break lands mid-token, which silently
# corrupts the span. See checks/markdown/split-code-spans.py, the backstop for
# the pathological cases a reflow cannot reach.
#
# KNOWN LIMIT — this setting LAUNDERS a mid-token break. Prettier
# joins a split span by printing the span's CommonMark VALUE, and
# that value already holds the space CommonMark put where the
# newline was. So `programs.claude-code.\nmarketplaces` comes out as
# `programs.claude-code. marketplaces`: one line, space intact,
# defect preserved — and now with no newline for
# checks/markdown/split-code-spans.nix to find. That class is NOT lintable
# (measured: a glue-char-plus-space heuristic gives 96 hits, ~90%
# legitimate), so it is prevented at authoring time by the
# markdown-formatting fragment instead. 10 code-span and 22 prose
# instances were cleaned up by hand in #590 and #591.
#
# FORMATTER CHOICE IS SETTLED — do not re-survey. Measured
# 2026-07-29: no Rust-family markdown formatter joins a split span
# at all. dprint-markdown `textWrap: always` reflows the paragraph
# and keeps the newline INSIDE the span; deno fmt uses the same
# engine; rumdl is a markdownlint clone with no reflow. Only
# prettier and mdformat manage it, and mdformat joins WITHOUT
# rewrapping (110-160 char lines) besides escaping `\<150` and
# renumbering ordered lists. The fragment carries the table.
#
# printWidth is deliberately left at prettier's default of 80.
# NOTE proseWrap also governs YAML folded/plain scalars, so
# changing it reflows .github/** too — verify semantics by parsing
# both revisions and diffing the loaded structures, not by eye.
{proseWrap = "always";}

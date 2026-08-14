# The AI runtime registry — every harness that goes through `mkAiApp`.
#
# PLAIN DATA ON PURPOSE. No module, no function, no arguments: `import` it and
# you have the list. That shape is a hard requirement rather than a style
# choice, because the four consumers have nothing in common to pass it —
#
#   - lib/ai/sharedOptions.nix is a bare Home Manager / devenv module, and
#     lib/ai/mkSkillPackageModule.nix is a factory whose RESULT is one. Either
#     way the code runs inside a CONSUMER's own evaluation, with module args and
#     no flake context — in particular no `self`. That is what rules out the
#     `cacheHitParityTargets` shape
#     (config/cache-hit-parity-targets.nix + lib/checks.nix merged by
#     `lib.evalModules` in flake.nix), which is reachable only as
#     `self.cacheHitParityTargets`.
#   - checks/options-doc.nix needs it inside a derivation's shell string.
#   - checks/module-eval.nix needs it in a plain `let`.
#
# (Both modules DO receive `pkgs` as a module argument; the missing thing is
# flake context, not package set. An earlier draft of this comment said "no
# `pkgs` at the point of use", which is simply wrong — sharedOptions.nix builds
# a `writeShellApplication` from it nine lines later.)
#
# It is deliberately NOT re-exported through lib/ai/default.nix. That barrel is
# the published `nat.lib.ai.*` API; this list is an internal invariant, and
# publishing it would make every future runtime addition a consumer-visible
# API event.
#
# ── Adding or removing a runtime ──
#
# Change this list and all four consumers follow. None of them holds a
# narrower view, and none needs a per-consumer filter.
#
# That was an open question rather than an assumption. checks/options-doc.nix
# previously hardcoded a FOUR-element list without kimchi, and whether adding
# kimchi would pass its two new CommonMark grep assertions was unmeasured. It
# was then measured, both renderings, with a negative control to prove the
# greps discriminate: `ai\.kimchi\.enable` is present in both, so the
# substitution is a strict tightening. kimchi's absence was a coverage gap
# dating from #694, not a deliberate exclusion — its HM and devenv facets
# predate that check by about six weeks.
#
# ── What does NOT belong here ──
#
# Not every list of runtime names in this repo is a stale copy of this one.
# Three are genuine CAPABILITY SUBSETS and folding them in would change
# behavior, not deduplicate it:
#
#   packages/semble/modules/options.nix:5, :34  — ["claude" "codex" "kiro"]
#   packages/semble/modules/common.nix:22       — ["claude" "codex" "kiro"]
#
# Widening those to five would newly fan semble into ai.copilot.* and
# ai.kimchi.*. The `semble-umbrella-fanout` test in `checks/module-eval.nix`
# asserts directly against the COPILOT half (`!(cfg.ai.copilot.mcpServers ?
# semble)` and the matching `agents` assertion), so that arm fails loudly; the
# kimchi arm has no such assertion and would simply start emitting. Ask if a list
# means "every runtime" or "the runtimes this feature supports" before pointing
# it here.
#
# (Cited by TEST NAME, not line number. An earlier revision of this comment
# cited `module-eval.nix:2641-2642`, and adding the provenance guard above it
# shifted the assertion to :2706 — a line cite into a 9800-line file rots on
# any edit anywhere above it.)
#
# Sorted alphabetically, per the repo's ordering standard.
[
  "claude"
  "codex"
  "copilot"
  "kimchi"
  "kiro"
]

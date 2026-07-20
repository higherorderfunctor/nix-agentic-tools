# Compose an app's single always-on instructions file: its global context
# baseline followed by any UNNAMED always-on instructions. NAMED instructions
# live in their own auto-loaded per-name files and are intentionally excluded
# here.
#
# Used by the single-file apps (Claude, Copilot) whose native context file must
# carry BOTH context and unnamed instructions through ONE writer — replacing the
# generic aggregate render that previously raced the per-app context writer and
# collided on `~/.claude/CLAUDE.md`. Kiro is directory-native and does NOT use
# this helper: it emits context and unnamed instructions as separate steering
# files.
#
# Args:
#   effectiveContext   string | path | null — the per-app resolved context
#                      (`cfg.context` else top-level `ai.context`).
#   unnamedInstructions list of instruction fragments carrying no `name` field.
#   render             the app's transformer render function
#                      (`fragment -> string`, e.g. `lib.ai.transformers.claude.render`).
#
# Short-circuit: with NO unnamed instructions the context is returned UNCHANGED
# (a path stays a path, so the caller can still `*.source` it), keeping the
# common case byte-identical to a bare context write. With unnamed instructions
# present a path context is `readFile`'d and the result is
# `[context]\n\n[rendered unnamed instructions]`, dropping empty segments.
{lib}: {
  effectiveContext ? null,
  unnamedInstructions ? [],
  render,
}:
if unnamedInstructions == []
then effectiveContext
else let
  contextText =
    if effectiveContext == null
    then ""
    else if builtins.isPath effectiveContext
    then builtins.readFile effectiveContext
    else effectiveContext;
  rendered = lib.concatMapStringsSep "\n\n" render unnamedInstructions;
in
  builtins.concatStringsSep "\n\n" (
    builtins.filter (s: s != "") [contextText rendered]
  )

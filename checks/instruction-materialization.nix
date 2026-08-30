# Behavioral contract for the real-file repository instruction materializer.
{
  instr,
  materializer,
  pkgs,
}:
pkgs.runCommandLocal "instruction-materialization-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.diffutils];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  root="$PWD/repository"
  mkdir -p "$root"
  ${pkgs.lib.getExe materializer} all "$root"

  for file in \
    AGENTS.md \
    CLAUDE.md \
    .claude/rules/nix-standards.md \
    .github/copilot-instructions.md \
    .github/instructions/pipeline.instructions.md \
    .kiro/steering/pipeline.md; do
    test -f "$root/$file"
    test ! -L "$root/$file"
    test "$(stat --format=%a "$root/$file")" = 644
  done

  cmp ${instr.agents}/AGENTS.md "$root/AGENTS.md"
  cmp ${instr.claude}/CLAUDE.md "$root/CLAUDE.md"
  diff -r ${instr.claude}/rules "$root/.claude/rules"
  cmp ${instr.copilot}/copilot-instructions.md "$root/.github/copilot-instructions.md"
  diff -r ${instr.copilot}/instructions "$root/.github/instructions"
  diff -r ${instr.kiro} "$root/.kiro/steering"

  # Same bytes, type, and mode are a no-op: shell reloads do not churn mtimes.
  touch --date=@1 "$root/AGENTS.md"
  ${pkgs.lib.getExe materializer} agents "$root"
  test "$(stat --format=%Y "$root/AGENTS.md")" = 1

  # Correct bytes are insufficient if the projection is a store symlink or has
  # inherited a read-only mode; both are repaired to a portable 0644 file.
  rm "$root/AGENTS.md"
  ln -s ${instr.agents}/AGENTS.md "$root/AGENTS.md"
  ${pkgs.lib.getExe materializer} agents "$root"
  test ! -L "$root/AGENTS.md"
  chmod 0400 "$root/AGENTS.md"
  ${pkgs.lib.getExe materializer} agents "$root"
  test "$(stat --format=%a "$root/AGENTS.md")" = 644

  # Managed directories are mirrors. Retired files, including dangling
  # symlinks, cannot survive a fragment rename indefinitely.
  echo stale > "$root/.claude/rules/stale.md"
  ln -s /does/not/exist "$root/.kiro/steering/dangling.md"
  ${pkgs.lib.getExe materializer} all "$root"
  test ! -e "$root/.claude/rules/stale.md"
  test ! -L "$root/.kiro/steering/dangling.md"

  mkdir -p "$out"
  touch "$out/ok"
''

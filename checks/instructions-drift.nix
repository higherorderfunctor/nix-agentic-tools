# Drift check — the TRACKED generated files must match what the
# generator produces from the current fragments.
#
# Why this exists. Generated content splits into two populations with
# very different guarantees:
#
#   * GITIGNORED (.claude/rules/*, .kiro/steering/*) — materialized on
#     devenv shell entry and gated by devenv.nix's enterTest, which
#     asserts they land as REAL files rather than store symlinks.
#   * TRACKED (the four files plus the instructions/ tree below) —
#     committed by hand, and until this check nothing anywhere
#     asserted they matched their source.
#
# Nothing covered the second group. Pre-commit is deliberately narrow
# (formatting and secrets only). enterTest checks that AGENTS.md exists
# and is not a symlink, which a stale AGENTS.md satisfies perfectly.
# devenv-test would not help either: it gates the gitignored population,
# and its path filter lists dev/generate.nix and dev/instructions.nix —
# the registration and the renderer — but not dev/fragments/**, so a
# fragment-content edit never triggered it at all.
#
# The consequence was not theoretical. Both repo-root documents drifted
# far enough to be wrong: README.md's install example set `ai.enable`,
# an option that does not exist, so the first snippet a new user copied
# failed to evaluate; CONTRIBUTING.md still told contributors to add an
# nvfetcher entry, a workflow the repo forbids.
#
# Living in `nix flake check` is deliberate. That is the repo's stated
# validation entrypoint, it is covered by the required `build`/`test`
# status checks, it has no path filter to fall through, and it adds no
# new required-context string that a job rename could silently break.
#
# Scope: TRACKED files only. The gitignored rules/ and steering/ trees
# that instructions-claude and instructions-kiro also emit are out of
# scope here — enterTest owns those. CLAUDE.md is likewise gitignored
# (it is a 24-byte `@AGENTS.md` pointer materialized on shell entry),
# so it is deliberately absent below: a flake check cannot read an
# untracked file, and enterTest already asserts it lands as a real
# file.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  drv = self.packages.${system};

  # Each entry: the tracked path, and the generated file to compare it
  # against. `label` is what the failure message names, so it must read
  # as the repo-relative path a human would go fix.
  files = [
    {
      label = "AGENTS.md";
      tracked = ../AGENTS.md;
      generated = "${drv.instructions-agents}/AGENTS.md";
      regenerate = "generate:instructions:agents";
    }
    {
      label = "CONTRIBUTING.md";
      tracked = ../CONTRIBUTING.md;
      generated = "${drv.repo-contributing}/CONTRIBUTING.md";
      regenerate = "generate:repo:contributing";
    }
    {
      label = "README.md";
      tracked = ../README.md;
      generated = "${drv.repo-readme}/README.md";
      regenerate = "generate:repo:readme";
    }
    {
      label = ".github/copilot-instructions.md";
      tracked = ../.github/copilot-instructions.md;
      generated = "${drv.instructions-copilot}/copilot-instructions.md";
      regenerate = "generate:instructions:copilot";
    }
  ];

  # `2>&1` so a diff-level error (a missing path, a permission fault)
  # lands in the captured output too — otherwise it goes to the real
  # stderr and the printed diff is blank, hiding why the check failed.
  compareOne = f: ''
    if ! "$diff" -u "${f.tracked}" "${f.generated}" >"$tmp/diff" 2>&1; then
      failed=1
      echo "" >&2
      echo "DRIFT: ${f.label}" >&2
      echo "  regenerate with: devenv tasks run --mode before ${f.regenerate}" >&2
      "$sed" -n '1,80p' "$tmp/diff" >&2
    fi
  '';
in {
  instructions-drift = pkgs.runCommand "instructions-drift" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    diff="${pkgs.diffutils}/bin/diff"
    sed="${pkgs.gnused}/bin/sed"
    tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
    failed=0

    ${builtins.concatStringsSep "\n" (map compareOne files)}

    # The Copilot instruction files are compared as a TREE rather than
    # file by file: a fragment that is renamed away, or a new one that
    # was never committed, changes the SET of files. Comparing only the
    # names we happen to list here would miss both.
    if ! "$diff" -r -u "${../.github/instructions}" \
      "${drv.instructions-copilot}/instructions" >"$tmp/diff-dir" 2>&1; then
      failed=1
      echo "" >&2
      echo "DRIFT: .github/instructions/" >&2
      echo "  regenerate with: devenv tasks run --mode before generate:instructions:copilot" >&2
      "$sed" -n '1,80p' "$tmp/diff-dir" >&2
    fi

    if [ "$failed" -ne 0 ]; then
      echo "" >&2
      echo "Tracked generated files are out of sync with their fragments." >&2
      echo "Regenerate, then 'git add' the results — flakes only see tracked files." >&2
      exit 1
    fi

    echo "ok — every tracked generated file matches its source" > $out
  '';
}

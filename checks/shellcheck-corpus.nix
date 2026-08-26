# Tree-wide shellcheck gate — lints EVERY tracked shell script in the repo
# with the shared opt-in flag set from config/shell-strict.nix.
#
# WHY THIS EXISTS. `config/shell-strict.nix` describes its `--enable=` list as
# "a regression gate, not a cleanup task — a new entry must be clean on the
# whole corpus before it lands." Nothing enforced that. The list was adopted
# 2026-07-30 (#614), verified clean across the then-24 tracked `*.sh` files;
# four fixture scripts carrying seven SC2249 findings landed the NEXT DAY in
# #618 and sat on main for four weeks. The corpus doubled (24 -> 54 files)
# under that blind spot.
#
# Two independent gaps let that happen, and this check closes both:
#
#   1. The prek `shellcheck` hook is `lib.optionalAttrs (!isCI)` in devenv.nix,
#      so it runs ZERO hooks in CI. Same reasoning as checks/doubled-words.nix:
#      a local-only, `--no-verify`-skippable hook does not cover the path the
#      defect actually took, which was a PR.
#   2. A pre-commit hook only ever sees STAGED files. A script can land dirty
#      and stay invisible until someone happens to run `prek run --all-files`.
#      That is the gap that hid #618 — not CI's absence alone.
#
# So this is deliberately a corpus scan, not a changed-files scan. A gate that
# only looks at the diff cannot notice that the tree behind it has rotted.
# The prek hook stays as the fast local mirror; this is the authority.
#
# WHICH FILES: every tracked regular file that is a shell script, by either
# signal — a `.sh` / `.bash` extension, or a first line naming sh/bash/dash/ksh.
# That mirrors what prek's `types: ["shell"]` tags (extension OR shebang) and
# is a slight SUPERSET of it, which is the safe direction to drift: CI is
# stricter than the local hook, never looser. It currently adds `.envrc` and
# the two extensionless hooks under `checks/fixtures/claude-hooks/`.
#
# The shebang arm is why this does not key off the executable bit. `.envrc` is
# mode 644 and is still a shell script; git tracks only a coarse exec bit, and
# what reaches a flake sandbox is a copy. Content is the reliable signal.
#
# THERE ARE NO EXCLUSIONS, and that is a measured claim rather than an
# aspiration: the whole 54-file corpus is clean under these flags as of this
# commit. Adding an exclusion here silently un-gates a file, so prefer fixing
# the script. If a file genuinely cannot pass, a targeted `# shellcheck
# disable=` at the offending line keeps the exemption visible in the source.
#
# Only git-tracked files reach the sandbox — see the "Flake Source Visibility"
# note in the nix-standards fragment — so a new script must be `git add`ed
# before this check can see it.
#
# AN EMPTY FILE SET IS A HARD FAILURE, for the reason spelled out at length in
# checks/markdown-scan.nix: a scan of nothing exits 0 and is indistinguishable
# from a pass. The resolved count is echoed so a set that SHRINKS is visible in
# the build log rather than silently reported as green.
{
  lib,
  pkgs,
  ...
}: let
  # Same single source of truth the prek hook and every writeShellApplication
  # call site read — see config/shell-strict.nix.
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.runCommandLocal "shellcheck-corpus-check" {
    src = ../.;
    nativeBuildInputs = [pkgs.findutils pkgs.coreutils pkgs.shellcheck];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cd "$src"

    # Held in a variable because `[[ $x =~ <literal> ]]` cannot carry a quoted
    # regex (bash 3.2+ treats a quoted right-hand side as a literal string) and
    # an unquoted one cannot contain the space this pattern needs.
    shebang_re='^#!.*[ /](sh|bash|dash|ksh)([ ]|$)'

    {
      find . -type f \( -name '*.sh' -o -name '*.bash' \) -print0
      # `read` rather than `head | grep`: no subprocess per file over an
      # 800-file tree, and no pipeline whose SIGPIPE would surface through
      # `pipefail` as a false negative on the files that DO match.
      find . -type f ! -name '*.sh' ! -name '*.bash' -print0 |
        while IFS= read -r -d "" f; do
          first=""
          IFS= read -r first < "$f" || true   # exit 1 on a final line with no newline
          if [[ $first =~ $shebang_re ]]; then printf '%s\0' "$f"; fi
        done
    } | sort -z -u > "$TMPDIR/shell-files"

    mapfile -d "" -t files < "$TMPDIR/shell-files"

    if [ "''${#files[@]}" -eq 0 ]; then
      echo "ERROR: shellcheck-corpus matched zero shell scripts." >&2
      echo "The file set moved out from under this check — a passing scan of" >&2
      echo "nothing is not a pass. Check the find predicates and the shebang" >&2
      echo "regex above, and that the scripts are git-tracked (untracked files" >&2
      echo "never reach a flake sandbox)." >&2
      exit 1
    fi

    echo "shellcheck-corpus: linting ''${#files[@]} shell scripts"

    # `-x` follows `source`d files, which resolve relative to the repo root —
    # hence the `cd "$src"` above and the relative `./` paths from find.
    if ! shellcheck -x ${lib.escapeShellArgs shellStrict.shellcheckFlags} \
      --format=gcc "''${files[@]}"; then
      echo "" >&2
      echo "shellcheck-corpus: findings above. These flags are the repo-wide" >&2
      echo "opt-in set from config/shell-strict.nix; the prek 'shellcheck'" >&2
      echo "hook applies the same ones locally, but only to STAGED files, so" >&2
      echo "a clean commit does not imply a clean tree." >&2
      exit 1
    fi

    mkdir -p "$out"
    touch "$out/ok"
  ''

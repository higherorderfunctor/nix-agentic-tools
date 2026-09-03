# Shared plumbing for the repo's markdown PROSE scanners.
#
# Two checks walk the same file set with the same traps:
#
#   - checks/split-code-spans.nix — an inline `code span` straddling a newline
#   - checks/doubled-words.nix    — a word repeated back to back in prose
#
# The file set, its exclusions and the empty-set guard live here once. A
# second copy of that list is exactly the failure this repo guards against:
# the two scans would drift apart silently, and the only symptom would be
# coverage neither check claims to have lost.
#
# WHICH FILES: every `.md` in the source tree, minus treefmt's own markdown
# exclusions, which are three:
#
#   - `docs/plan.md` — sentinel-tip scratch that never merges.
#   - `docs/plans/kiro-v3-research-raw/` — a verbatim research snapshot whose
#     as-authored text is deliberately preserved (see the treefmt.nix comment
#     for the mangling that reformatting it causes).
#   - `dev/probes/kiro-steering/fixture/` — steering probe documents whose
#     deliberately-malformed YAML frontmatter IS the experiment; normalizing
#     it into a parsable shape deletes the finding (see that directory's
#     README).
#
# treefmt.nix states those exclusions for the FORMATTER and this is their
# scan-side mirror; keep the two in step. Each excluded directory also
# documents its own exclusion — docs/plans/kiro-v3-research-raw/README.md and
# dev/probes/kiro-steering/README.md both do — so renaming any one of them
# spans THREE surfaces: treefmt.nix, this file, and that directory's README.
# Stating the exclusion once here rather than once per scanner is what keeps
# that count at three instead of growing with the scanners. Deriving them
# mechanically from `settings.global.excludes`
# was rejected: that list is glob-shaped and mostly about non-markdown
# files, so a glob-to-find translation would be a second source of truth
# wearing a derivation's clothes.
#
# Only git-tracked files reach the sandbox — see the "Flake Source
# Visibility" note in the nix-standards fragment — so a new file must be
# `git add`ed before either check can see it.
#
# `-type f` does not match symlinks, so tracked store symlinks (e.g.
# `dev/skills/repo-review/references/*.md`) go unscanned. That is deliberate
# and costs no coverage: their content is generated from sources these scans
# already read. It is stated because a silent skip otherwise reads as
# coverage the checks do not have.
#
# AN EMPTY FILE SET IS A HARD FAILURE. The original shape here was
# `find … -print0 | xargs -0 -r`, and it was not enough. `-r` makes an empty
# tree run the scanner zero times and the check exits 0; dropping `-r` runs
# it once with no arguments and the scanner reports success on a file set it
# never received. Both are green, so neither distinguishes an empty scan
# from a passing one — `-r` only suppressed the misleading success MESSAGE.
# Reading the NUL list into a bash array instead makes the count observable,
# and a count of zero fails the check. `-print0` still earns its keep: it is
# what makes paths with spaces survive. `mapfile -t` is load-bearing too —
# without it every element retains its NUL delimiter and every path is
# wrong.
#
# Each scanner's `main()` refuses an empty argument list as well, and that
# duplication is deliberate: this guard protects THIS CALLER, and the
# invariant has to survive a second one being added (a prek mirror is the
# obvious candidate). See `no_files` in ./split-code-spans.py.
#
# THE SCANNERS SHARE ONE STORE DIRECTORY, built by ./markdown-scanners.nix
# so that ./doubled-words-fixtures.nix can reuse it rather than assemble a
# second copy. That file carries the rationale for the directory and for
# the `-` → `_` module rename.
{pkgs, ...}: let
  scanners = import ./markdown-scanners.nix {inherit pkgs;};
in
  {
    # Derivation name, and the attribute name the check is registered under.
    name,
    # Python module in `scanners` to run. It receives every markdown path as
    # an argument and must exit non-zero on any finding.
    entrypoint,
  }:
    pkgs.runCommandLocal name {
      src = ../.;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      cd "$src"

      ${pkgs.findutils}/bin/find . \
        -path './docs/plans/kiro-v3-research-raw' -prune -o \
        -path './dev/probes/kiro-steering/fixture' -prune -o \
        -type f -name '*.md' \
        ! -path './docs/plan.md' \
        -print0 > "$TMPDIR/markdown-files"

      mapfile -d "" -t files < "$TMPDIR/markdown-files"

      if [ "''${#files[@]}" -eq 0 ]; then
        echo "ERROR: ${name} matched zero markdown files." >&2
        echo "The file set moved out from under this check — a passing scan" >&2
        echo "of nothing is not a pass. Check the find exclusions above, and" >&2
        echo "that the files are git-tracked (untracked files never reach a" >&2
        echo "flake sandbox)." >&2
        exit 1
      fi

      ${pkgs.python3}/bin/python3 ${scanners}/${entrypoint} "''${files[@]}"

      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/touch "$out/ok"
    ''

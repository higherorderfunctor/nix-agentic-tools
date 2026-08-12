# Doubled-word lint — catches a word repeated back to back in markdown
# prose ("is the the rootfs top level").
#
# EVERY MEASURED FIGURE FOR THIS CHECK LIVES IN THE MODULE DOCSTRING OF
# ./doubled-words.py, and only there: corpus size, precision, the
# tokenization bugs behind the first cut's false positives, the coverage
# boundary of the prose extraction, why there is no stopword list, and the
# suppression marker. Read that file before changing either half, and put
# any new measurement there rather than restating it here.
#
# Division of labour with the rest of the markdown toolchain — this check
# is not a backstop for anything, it is the ONLY thing that can see the
# defect:
#
#   - prettier (`settings.proseWrap = "always"` in treefmt.nix) reflows the
#     paragraph and reproduces the duplicate verbatim. It also decides
#     which side of a newline the pair lands on, which is why the scanner
#     has to handle both.
#   - cspell checks words in isolation; both halves are correctly spelled.
#   - checks/split-code-spans.nix reasons about backtick pairing, not word
#     sequences.
#
# `is the the rootfs top level` shipped in #878 and reached main through
# review with all three of those green. That is the measured justification
# for the gate, and it is a thin one — see #877.
#
# This is a `nix flake check` rather than a prek hook on purpose. The prek
# hooks are `lib.optionalAttrs (!isCI)` in devenv.nix — local-only and
# `--no-verify`-skippable — and the one measured instance of this defect
# entered through a PR, which is the path a local-only hook does not
# cover. It also propagates: a doubled word in a source fragment is copied
# into every generated projection of it, so the cheap moment to stop it is
# before main, not before a commit.
#
# The file set, exclusions and empty-set guard come from
# ./markdown-scan.nix, shared with checks/split-code-spans.nix.
#
# This check measures the scanner against the repo's real markdown.
# ./doubled-words-fixtures.nix is its other half — the per-shape
# regression suite — and the two are not interchangeable: a corpus count
# cannot fail on a shape the corpus lacks. Read the comment there before
# assuming either one covers the other.
{pkgs, ...}:
(import ./markdown-scan.nix {inherit pkgs;}) {
  name = "doubled-words-check";
  entrypoint = "doubled_words.py";
}

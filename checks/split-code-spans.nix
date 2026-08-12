# Split-inline-code-span lint — catches markdown where a `code span`
# straddles a newline.
#
# Rationale, the scanner's CommonMark rule, and why a naive regex is wrong
# all live in the module docstring of ./split-code-spans.py. Read that file
# before changing either half.
#
# Division of labour with treefmt:
#
#   - prettier (`settings.proseWrap = "always"` in treefmt.nix) is the
#     PRIMARY guardrail. It treats a code span as an unbreakable token, so
#     it joins any split span on format and can never emit one. Regressions
#     are caught by checks/formatting.nix, which already gates the tree.
#   - This check is the BACKSTOP for the residue prettier cannot reach:
#     CASCADING backtick mis-nesting, where one mis-paired span shifts every
#     backtick after it and prettier's own parse goes wrong (it DOES repair
#     an isolated one — see the docstring for the control that establishes
#     the distinction), plus any file excluded from prettier in treefmt.nix.
#
# The file set this scans, its exclusions, the `-type f` symlink caveat and
# the caller-side empty-set guard moved to ./markdown-scan.nix when
# checks/doubled-words.nix started sharing them; the rationale for each is
# preserved there verbatim. The scanner keeps its OWN empty-set guard
# (`no_files`) so the invariant survives a second caller — see that
# function. ./split-code-spans.py is also copied into the shared scanner
# directory as `split_code_spans.py`, so doubled_words.py can import its
# CommonMark backtick rule and its list-aware code-block stripper rather
# than keep a second copy of either.
{pkgs, ...}:
(import ./markdown-scan.nix {inherit pkgs;}) {
  name = "split-code-spans-check";
  entrypoint = "split_code_spans.py";
}

# THE MARKDOWN SCANNERS, ASSEMBLED INTO ONE STORE DIRECTORY.
#
# Three consumers share it, which is the whole reason it is its own file:
# ./markdown-scan.nix runs a scanner over the repo's markdown, and
# ./doubled-words-fixtures.nix runs the fixture suite over
# ./fixtures/doubled-words. Building a second copy in either would be a
# second place for the module list to drift.
#
# One directory rather than three lone files so doubled_words can `import`
# the CommonMark backtick rule and the list-aware code-block stripper from
# split_code_spans instead of carrying a second copy of either.
# `${./split-code-spans.py}` on its own lands as a lone file in /nix/store,
# whose dirname is /nix/store itself, so there is no importable package
# without this step. The `-` → `_` rename is forced: `split-code-spans` is
# not a legal Python module name, and it is why a traceback names
# `split_code_spans.py` while the source file has a hyphen. The fixture
# runner also falls back to loading the hyphenated files by path, so it
# stays runnable straight from a checkout — see its `_load`.
{pkgs, ...}:
pkgs.runCommandLocal "markdown-scanners" {} ''
  ${pkgs.coreutils}/bin/mkdir -p "$out"
  ${pkgs.coreutils}/bin/cp ${./split-code-spans.py} "$out/split_code_spans.py"
  ${pkgs.coreutils}/bin/cp ${./doubled-words.py} "$out/doubled_words.py"
  ${pkgs.coreutils}/bin/cp ${./doubled-words-fixtures.py} "$out/doubled_words_fixtures.py"
''

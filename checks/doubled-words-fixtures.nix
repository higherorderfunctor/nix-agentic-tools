# Fixture suite for the doubled-word scanner — the regression half of its
# validation, next to the corpus measurement in ./doubled-words.py's
# docstring.
#
# The two answer different questions and neither substitutes for the other.
# The corpus says how the current rule scores on the 220 markdown files this
# repo happens to have; it cannot fail on a shape the corpus does not
# contain, and when its number moves it does not say which rule moved it.
# The fixtures pin the shapes: a GFM task-list continuation, a plain and a
# nested bullet continuation, top-level indented code, a fenced block, a
# fence opened at column 4 inside a nested item, a cross-line pair, and the
# hyphen-glue negative control. Each states in its header what it proves and
# the exact hits it expects.
#
# That split is not theoretical. The task-list bug shipped past a corpus
# measurement that reported 272 blanked lines and called all of them code;
# 215 were prose, and the nine-line fixture in this directory says so in
# under a second.
#
# The fixtures are `*.md.fixture`, NOT `*.md`, and that is load-bearing —
# ./markdown-scan.nix scans every tracked `.md` in the tree (seven under
# checks/fixtures/ today), so a `.md` fixture carrying a deliberate doubling
# would fail the check it tests, and prettier would reflow away the exact
# indentation it encodes. See fixtures/doubled-words/README.md.fixture.
{pkgs, ...}: let
  scanners = import ./markdown-scanners.nix {inherit pkgs;};
in
  pkgs.runCommandLocal "doubled-words-fixtures-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${pkgs.python3}/bin/python3 \
      ${scanners}/doubled_words_fixtures.py \
      ${./fixtures/doubled-words}

    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/touch "$out/ok"
  ''

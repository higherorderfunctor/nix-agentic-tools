# cspell:ignore PYTHONDONTWRITEBYTECODE sdoc
# checks/strictdoc-element-check.nix -- the CI gate for element-grained File
# relations: every `ELEMENT`/`ID` in the corpus, resolved against the file it
# points into by the same extractor table the write path uses
# (dev/scripts/sdoc_extractors/registry.py).
#
# A ghost `ID:` EXPORTS CLEAN and RENDERS CLEAN. strictdoc drops a forward id
# it cannot resolve with exit 0, no marker, and the relation missing from both
# pages, so a corpus of ghosts and a sound corpus are indistinguishable from
# outside. checks/strictdoc-file-check.nix cannot see it: that gate checks the
# PATH and never opens the file.
#
# The write-time refusal in dev/scripts/sdoc_model.py does not replace this
# one, for the same reason MECH-FILE-RELATION-EXISTENCE's gate does not replace
# its write-time path check: the write-time check sees the values it is about
# to write, and the ghost problem runs the other way -- a binding RENAMED after
# its relation was written turns a sound id into a dangling one with no edit to
# any `.sdoc`.
#
# THE RUNNER IS `strictdocGrammarExtract`, NOT `pkgs.python3`. This gate parses
# source with tree-sitter, so it needs the one interpreter that carries both
# strictdoc and `tree_sitter` plus `SDOC_TS_NIX_PARSER` -- the same wrapper the
# dev shell hands every scribe program, so a session and CI resolve ids through
# one grammar.
#
# `element-check.py` reads the MODEL rather than a JSON export, unlike
# file-check.py, and that is not a style difference: `strictdoc export
# --formats=json` DROPS ELEMENT and ID (only sdoc_model's
# carry_file_element_into_json patch restores them), so a gate written against
# a bare export would find zero relations in a corpus that has three and be
# green forever. See the script's header.
#
# ── The positive control ─────────────────────────────────────────────────────
#
# "0 findings" is worthless on its own here: a checker that resolves nothing at
# all reports exactly that. So the second arm builds a SCRATCH corpus whose
# first element-grained relation carries a deliberately impossible id, and the
# gate fails unless the checker exits 1 on it and names the ghost.
#
# The scratch corpus is a SYMLINK FARM (`cp -rs`) rather than a copy: it is the
# whole repository as far as strictdoc's walk is concerned, at the cost of one
# inode per file and no file data. The one victim `.sdoc` is replaced with a
# real file. The checker's glob matcher is careful to relativize a path WITHOUT
# resolving it first, which is what makes a farm like this work at all -- see
# `relative_to` in dev/scripts/sdoc_extractors/registry.py.
#
# The victim is DISCOVERED, not named: hardcoding a node here would rot the
# moment that node moved, and the failure would look like a broken control
# rather than a moved file. A corpus carrying no element-grained relation at
# all cannot furnish a control; that is reported loudly and left green, because
# an empty relation set is a legitimate state for this corpus and not a defect.
{
  pkgs,
  self,
  strictdocGrammarExtract,
}:
pkgs.runCommand "strictdoc-element-check" {
  nativeBuildInputs = [
    strictdocGrammarExtract
    pkgs.ai.devTools.strictdoc
    pkgs.python3
  ];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  # The sources are read-only store paths; without this python tries (and
  # silently fails) to drop a __pycache__ beside each of them.
  export PYTHONDONTWRITEBYTECODE=1

  echo "== 1. every element-grained relation in the corpus resolves ==" | tee "$out"
  strictdoc-grammar-extract ${self}/dev/scripts/element-check.py ${self} \
    --output-dir "$TMPDIR/out" | tee -a "$out"

  echo "== 2. positive control: a ghost id is refused ==" | tee -a "$out"
  repo="$TMPDIR/repo"
  cp -rs ${self} "$repo"
  # DIRECTORIES ONLY, and that is guaranteed rather than hoped for: GNU chmod
  # "ignores symbolic links encountered during recursive directory
  # traversals", so this makes the copied directory entries writable and
  # cannot reach the store paths every file here links to. Without it the
  # directories inherit the store's r-xr-xr-x and the victim cannot be
  # replaced.
  chmod -R u+w "$repo"

  # The first document carrying an `ID:` slot. `|| true` because grep exits 1
  # on no match, which is the "corpus has none" case handled below rather than
  # a build failure.
  #
  # `-R`, NOT `-r`: every file in the farm is a symlink, and `-r` follows only
  # the symlinks named on the command line while SKIPPING those it meets
  # during recursion. Measured -- with `-r` the search returns nothing, the
  # branch below reports a corpus with no element-grained relation, and the
  # gate exits 0 having proved nothing on a corpus that has three.
  victim=$(grep -Rl --include='*.sdoc' '^  ID: ' "$repo" | sort | head -1 || true)

  if [ -z "$victim" ]; then
    echo "no element-grained File relation in the corpus: the positive" \
         "control cannot be constructed, and this gate proves nothing until" \
         "one exists" | tee -a "$out"
    exit 0
  fi

  ghost="sdoc-element-check-no-such-item"
  original=$(cat "$victim")
  rm -f "$victim"
  printf '%s\n' "$original" | sed "s|^  ID: .*|  ID: $ghost|" > "$victim"
  echo "control: $ghost written into ''${victim#$repo/}" | tee -a "$out"

  status=0
  strictdoc-grammar-extract ${self}/dev/scripts/element-check.py "$repo" \
    --output-dir "$TMPDIR/control-out" > "$TMPDIR/control.log" 2>&1 || status=$?
  cat "$TMPDIR/control.log"
  if [ "$status" -ne 1 ]; then
    echo "POSITIVE CONTROL FAILED: element-check exited $status on a corpus" \
         "whose id resolves to nothing; expected 1" >&2
    exit 1
  fi
  if ! grep -q "$ghost" "$TMPDIR/control.log"; then
    echo "POSITIVE CONTROL FAILED: element-check exited 1 but never named" \
         "the ghost id $ghost, so the failure was something else" >&2
    exit 1
  fi
  echo "control refused as expected" | tee -a "$out"
''

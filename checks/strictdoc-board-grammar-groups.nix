# cspell:ignore sgra sdoc
# checks/strictdoc-board-grammar-groups.nix -- the CI gate for the Grammars
# tab's hand-authored layout (docs/sdoc/board/grammar-groups.json). Runs
# dev/scripts/grammar-groups-check.py over the committed grammar render and
# the committed layout.
#
# The layout is the board's one deliberate departure from "everything is
# generated from the grammar": the operator groups the node types by hand so
# the tab reads as a reasoned map, and the stated price of that exception was
# a check that guards it (2026-09-02). The page re-runs the same rules at load
# time and shows a banner, but a banner is seen only by whoever opens the
# tab; this is the gate that fails a PR which adds, renames or removes a
# grammar type without placing it.
#
# The inputs are read straight from ${self}: grammar.sgra is the committed
# render of packages/strictdoc-grammar/values.nix (strictdoc-grammar-model-equal
# proves they agree), and it is the SAME file the daemon parses with the SAME
# parse_sgra the script imports, so the universe here is byte-for-byte what
# the tab renders. No export, no strictdoc, no HOME.
#
# THE SELF-TESTS ARE THE POINT. A green over a correct layout is
# indistinguishable from a checker that returns 0 unconditionally, so this
# build also feeds the script one bad layout PER RULE and asserts each exits
# NON-zero with the message that rule emits -- a bare non-zero would let the
# wrong rule stand in for the right one. Each fixture is a whole layout
# rather than a patch of the real one, so it cannot drift with the operator's
# grouping, and each keeps a "rest" group unless the rule under test is about
# "rest", so a grammar that grows a type does not turn a fixture red for a
# second reason. Fixtures are written to $TMPDIR, never to the store.
{
  pkgs,
  self,
}:
pkgs.runCommand "strictdoc-board-grammar-groups" {
  nativeBuildInputs = [pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  grammar=${self}/docs/sdoc/grammar.sgra
  layout=${self}/docs/sdoc/board/grammar-groups.json
  check() {
    python3 ${self}/dev/scripts/grammar-groups-check.py "$@"
  }

  # 1. the real layout must place every real grammar type
  check "$grammar" "$layout" | tee "$out"

  # 2. the checker must be able to FAIL, once per rule
  fixture() {
    cat > "$TMPDIR/$1.json"
  }
  expect_fail() {
    local name="$1" expected="$2" sgra="''${3:-$grammar}"
    if check "$sgra" "$TMPDIR/$name.json" >/dev/null 2>"$TMPDIR/err"; then
      echo "self-test FAILED: fixture '$name' passed the checker" >&2
      exit 1
    fi
    if ! grep -qF -- "$expected" "$TMPDIR/err"; then
      echo "self-test FAILED: fixture '$name' did not report: $expected" >&2
      cat "$TMPDIR/err" >&2
      exit 1
    fi
    echo "self-test: '$name' -> $expected" | tee -a "$out"
  }

  fixture stale <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["BOGUS"]},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail stale "BOGUS is not a type the grammar declares"

  fixture prefix <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["REQ-"]},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail prefix "'REQ-' is the UID prefix of REQUIREMENT"

  fixture unplaced <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["REQUIREMENT"]}]}]}
  JSON
  expect_fail unplaced "placed nowhere, and no group takes the 'rest'"

  fixture duplicate <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["REQUIREMENT", "REQUIREMENT"]},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail duplicate "REQUIREMENT is already placed at S/G"

  fixture two-rests <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "A", "widget": "cards", "types": "rest"},
    {"title": "B", "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail two-rests "at most one group takes the rest"

  fixture empty-cell <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "grid",
     "axes": {"rows": ["normative", "descriptive"], "columns": ["universal", "particular"]},
     "cells": {"REQUIREMENT": ["normative", "universal"], "DECISION": ["normative", "particular"],
               "MECHANISM": ["descriptive", "universal"]}},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail empty-cell "cell (descriptive, particular) is empty"

  fixture bad-axis-word <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "grid",
     "axes": {"rows": ["normative", "descriptive"], "columns": ["universal", "particular"]},
     "cells": {"REQUIREMENT": ["normative", "universal"], "DECISION": ["normative", "particular"],
               "MECHANISM": ["descriptive", "universal"], "EVIDENCE": ["descriptive", "one"]}},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail bad-axis-word "EVIDENCE names column 'one'"

  fixture double-cell <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "grid",
     "axes": {"rows": ["normative", "descriptive"], "columns": ["universal", "particular"]},
     "cells": {"REQUIREMENT": ["normative", "universal"], "DECISION": ["normative", "particular"],
               "MECHANISM": ["descriptive", "universal"], "EVIDENCE": ["normative", "universal"]}},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail double-cell "holds both REQUIREMENT and EVIDENCE"

  fixture unknown-widget <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "list", "types": ["REQUIREMENT"]},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail unknown-widget "widget 'list' is not one of"

  fixture gloss-unplaced <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["REQUIREMENT"],
     "glosses": {"DECISION": "A choice, open or closed."}},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail gloss-unplaced "'DECISION' has a gloss but is not a type this group lists"

  fixture gloss-axis-word <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "grid",
     "axes": {"rows": ["normative", "descriptive"], "columns": ["universal", "particular"],
              "glosses": {"general": "every case"}},
     "cells": {"REQUIREMENT": ["normative", "universal"], "DECISION": ["normative", "particular"],
               "MECHANISM": ["descriptive", "universal"], "EVIDENCE": ["descriptive", "particular"]}},
    {"title": null, "widget": "cards", "types": "rest"}]}]}
  JSON
  expect_fail gloss-axis-word "'general' has a gloss but is not a word of this grid's axes"

  fixture gloss-rest-placed <<'JSON'
  {"sections": [{"title": "S", "groups": [
    {"title": "G", "widget": "cards", "types": ["REQUIREMENT"]},
    {"title": null, "widget": "cards", "types": "rest",
     "glosses": {"REQUIREMENT": "What must always be true."}}]}]}
  JSON
  expect_fail gloss-rest-placed "'REQUIREMENT' has a gloss but is not a type the 'rest' absorbs"

  # a blind check must not pass: the REAL layout against an EMPTY grammar
  : > "$TMPDIR/empty.sgra"
  cp "$layout" "$TMPDIR/empty-grammar.json"
  expect_fail empty-grammar "declares no element types" "$TMPDIR/empty.sgra"
''

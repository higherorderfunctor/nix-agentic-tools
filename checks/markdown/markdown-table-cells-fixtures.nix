# Fixture suite for the `markdown-table-cells` gate — the regression half of
# its validation, and specifically the half that survives a tool update.
#
# WHAT IT GUARDS, and why the corpus cannot. The corpus scan says the repo is
# clean today. It cannot say WHICH linter earned that, and it goes on passing
# if one of the two silently stops working — a corpus with no broken tables in
# it reports the same green whether both tools are healthy or neither is.
#
# THE CLAIM UNDER TEST IS DISJOINTNESS, not detection. Two linters are carried
# because they share the rule NUMBER (MD056) and cover different halves of it:
#
#   header/delimiter disagree ("the break")  -> rumdl hits, markdownlint does not
#   excess body cell          ("the cause")  -> markdownlint hits, rumdl does not
#
# That asymmetry is the entire justification for the pair, and it is a MEASURED
# property of two third-party tools on this repo's update cadence — exactly the
# kind of claim that rots without anyone noticing. Both are absorbed overlays
# swept 4x/day, so either can change behavior on any sweep.
#
# So this suite fails LOUDLY in both directions:
#
#   - a tool stops catching its half  -> the gate has a hole; fix or replace it.
#   - a tool starts catching the OTHER half -> the pair may be redundant, and
#     the rationale in lib/markdown/table-cells.nix and the
#     markdown-formatting fragment is now WRONG and must be rewritten.
#
# The second direction is the one a plain "does it still find bugs?" test would
# miss, and it is the one that turns three files of prose into a lie.
#
# Each defect is the other linter's negative control. The generated-files
# check covers a plain valid table; guards-consumer covers the documented
# escaped-pipe remedy through the combined gate.
#
# The fixtures are `*.md.fixture`, NOT `*.md`, and that is load-bearing twice:
# `checks/markdown/markdown-scan.nix` walks every tracked `.md`, and the
# `markdown-table-cells` hook runs on every tracked `.md` — so a `.md` fixture
# carrying a deliberately broken table would fail the check it exists to test.
# treefmt would also rewrite the exact cell counts each one encodes.
{pkgs, ...}: {
  checks.markdown-table-cells-fixtures = let
    # The SAME two programs the hook's `markdown-table-cells` runs, one per
    # half, from lib/markdown/table-cells.nix: our overlay's rumdl and
    # markdownlint-cli2 under exactly the flags and rule set the gate uses,
    # not `pkgs.rumdl` / `pkgs.markdownlint-cli2` from the nixpkgs pin. A
    # fixture suite that validated different binaries or flags from the ones
    # the gate uses would be measuring nothing. The last case below runs the
    # combined script itself.
    tableCells = import ../../lib/markdown/table-cells.nix {inherit pkgs;};
    inherit (tableCells) markdownlintTables rumdlTables;

    fixtures = ./fixtures/markdown-table-cells;
  in
    pkgs.runCommandLocal "markdown-table-cells-fixtures-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # markdownlint-cli2 writes state under HOME and refuses a read-only one.
      export HOME="$TMPDIR"
      cd "$TMPDIR"

      fail() {
        echo "FAIL: $1" >&2
        echo "" >&2
        echo "This suite pins the DISJOINTNESS of two linters that share rule MD056." >&2
        echo "One of them changed behavior. Before touching this file, decide which:" >&2
        echo "  * a tool stopped catching its half  -> the gate has a hole." >&2
        echo "  * a tool started catching the other -> the pair may be redundant, and" >&2
        echo "    the rationale in lib/markdown/table-cells.nix plus the" >&2
        echo "    markdown-formatting fragment is now WRONG and must be rewritten." >&2
        echo "" >&2
        echo "Do not 'fix' this by relaxing the assertion." >&2
        exit 1
      }

      # Match a rule diagnostic for the requested file, not a summary count.
      # rumdl 0.3.7 prints `file:line:column: [MD056]` on stdout;
      # markdownlint-tables.mjs prints `file:line MD056` on stderr. Both put
      # the path and rule on one line: a layout change needs a matcher update.
      reports_md056() {
        local file="$1"
        shift
        ${pkgs.gnugrep}/bin/grep -wF MD056 "$@" | ${pkgs.gnugrep}/bin/grep -F -- "$file" >/dev/null
      }

      # A nonzero exit alone could be a crash or another rule, not MD056.
      check_linter() {
        local name="$1" tool="$2" want="$3" program="$4" rc=0 got=silent
        "$program" "$name.md" >linter.log 2>&1 || rc=$?
        if reports_md056 "$name.md" linter.log; then
          got=MD056
        elif ${pkgs.gnugrep}/bin/grep -qwF MD056 linter.log; then
          got=unattributed-MD056
        fi

        local want_rc=0
        if [ "$want" = MD056 ]; then want_rc=1; fi
        if [ "$rc" -ne "$want_rc" ] || [ "$got" != "$want" ]; then
          ${pkgs.coreutils}/bin/cat linter.log >&2
          fail "$name: $tool expected $want (exit $want_rc), got $got (exit $rc)"
        fi
      }

      # Copy each fixture once with the `.md` extension the tools expect,
      # leaving the tracked `.md.fixture` outside the corpus and formatter.
      check() {
        local name="$1" wantRumdl="$2" wantMdl="$3"
        ${pkgs.coreutils}/bin/cp "${fixtures}/$name.md.fixture" "$name.md"
        check_linter "$name" rumdl "$wantRumdl" ${pkgs.lib.getExe rumdlTables}
        check_linter "$name" markdownlint "$wantMdl" ${pkgs.lib.getExe markdownlintTables}
        echo "ok — $name: rumdl=$wantRumdl markdownlint=$wantMdl"
      }

      #      fixture                              rumdl    markdownlint
      check break-header-delimiter-disagree       MD056    silent
      check cause-excess-body-cell                silent   MD056

      # guards-consumer checks exit 1 and the body-cell finding in a mixed
      # batch. Pin the header diagnostic here: a missing file can also yield
      # exit 1 and a worked example, and a truncated diagnostic can leave no
      # usable fix. Require the worked example on stderr.
      ${pkgs.lib.getExe tableCells.package} break-header-delimiter-disagree.md cause-excess-body-cell.md >gate.stdout 2>gate.stderr || :
      if ! reports_md056 break-header-delimiter-disagree.md gate.stdout gate.stderr ||
        ! ${pkgs.gnugrep}/bin/grep -q -F 'fixed:   | id |' gate.stderr; then
        echo "FAIL: markdown-table-cells expected MD056 for the broken header and a worked example on stderr:" >&2
        ${pkgs.coreutils}/bin/cat gate.stdout gate.stderr >&2
        exit 1
      fi
      echo "ok — markdown-table-cells reports the broken header and prints the worked example"

      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/touch "$out/ok"
    '';
}

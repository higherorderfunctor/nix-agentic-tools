# cspell:ignore PYTHONDONTWRITEBYTECODE
# checks/strictdoc-grammar-negative-fixtures.nix -- acceptance item 6 of
# SLICE-GRAMMAR-FROM-NIX (packages/strictdoc-grammar/docs/implementation-brief.md).
#
# Every fixture under `fixtures/negative/` must be rejected, AT THE LAYER THAT
# OWNS THE RULE. "Something failed" is not the gate: a fixture that fails for
# the wrong reason -- a typo, a missing import, a broken harness -- looks
# exactly like one the surface correctly rejects, and would keep looking that
# way after the rule it stands for was removed.
#
# Three layers, and each is exercised by the mechanism that actually implements
# it:
#
#   OURS, at Nix evaluation. Duplicate field titles and duplicate relation
#     roles have no rule anywhere in strictdoc: both parse clean, both export
#     exit 0, and the silent recovery runs in OPPOSITE directions (last
#     declaration wins for fields, first wins for relations). They are checked
#     with `builtins.tryEval` over `render`, at evaluation time -- so this arm
#     of the check has already run before the derivation is built.
#   STRICTDOC's, at the textx parse of the `.sgra`. A bare
#     `SDocGrammarReader.read` must RAISE.
#   STRICTDOC's, at `SDocValidator`. A bare read must SUCCEED and the export
#     must fail. That asymmetry is the point, and it is the brief's MEASURED
#     claim made executable: `SDocValidator` is only ever called from the
#     traceability-index build, so a bare parse never runs it and a
#     clean-directory whole-corpus export is the only thing that does.
#
# fixtures/README.md IS THE SOURCE OF TRUTH for which layer owns which fixture.
# The expectation is read out of its table rather than restated here, so the
# two cannot drift apart, and the fixture directory and the table must name the
# same set -- an undocumented fixture and a documented-but-absent one both fail
# the check.
#
# POSITIVE CONTROLS, because every assertion here is of the form "this failed":
#   - a valid element, same plain-data shape as the two `.nix` fixtures, must
#     RENDER at Nix evaluation;
#   - `fixtures/foreign.sgra` must parse AND export cleanly through the exact
#     same throwaway-project harness the six invalid ones go through.
# Without both, a harness broken in any way at all would report a clean sweep.
#
# The throwaway project lives outside the repository under $TMPDIR: a
# whole-project export reads EVERY `.sgra` beneath the project root whether a
# document imports it or not, and `IMPORT_FROM_FILE` resolves only a bare
# filename beside the document. Each export gets its OWN fresh `--output-dir`;
# `strictdoc export` caches under that directory and a warm one turns a failing
# input into exit 0 on the next run.
{
  lib,
  pkgs,
  self,
}: let
  grammarDir = "${self}/packages/strictdoc-grammar";
  negativeDir = "${grammarDir}/fixtures/negative";

  grammar = import "${grammarDir}/lib" {inherit lib;};

  # Force the whole render. `render` returns a string, so taking its length
  # evaluates the type check in lib/check.nix and every assertion in
  # lib/emit.nix; `tryEval` turns the `throw` those raise into a verdict.
  renders = element: (builtins.tryEval (builtins.stringLength (grammar.render [element]))).success;

  # Enumerate rather than hand-list, so a new `.nix` fixture is covered the
  # moment it is committed instead of the moment somebody remembers this file.
  nixFixtures =
    lib.filter (lib.hasSuffix ".nix")
    (builtins.attrNames (builtins.readDir negativeDir));

  # The positive control for the Nix arm: the duplicate-field-title fixture
  # with the duplicate removed. Same plain-data shape against the same
  # normalized element type, so an accept and a reject travel the same path.
  validElement = {
    tag = "NOTE";
    prefix = "NOTE-";
    fields = [
      {
        string = {
          title = "UID";
          required = true;
        };
      }
      {
        string = {
          title = "STATEMENT";
          required = true;
        };
      }
    ];
  };

  manifest = pkgs.writeText "strictdoc-grammar-negative-manifest.json" (builtins.toJSON {
    inherit negativeDir;
    readme = "${grammarDir}/fixtures/README.md";
    validGrammar = "${grammarDir}/fixtures/foreign.sgra";
    nixControlAccepted = renders validElement;
    nixAccepted =
      lib.listToAttrs
      (map (name: lib.nameValuePair name (renders (import "${negativeDir}/${name}"))) nixFixtures);
  });

  script = pkgs.writeText "strictdoc-grammar-negative.py" ''
    # cspell:ignore sgra textx
    """Assert every negative fixture is rejected by the layer that owns it.

    The expected layer is read out of fixtures/README.md's table -- see the
    header of the .nix file that writes this script for why it is not restated
    here.
    """

    from __future__ import annotations

    import json
    import pathlib
    import re
    import shutil
    import subprocess
    import sys

    from strictdoc.backend.sdoc.grammar_reader import SDocGrammarReader

    # `| `negative/<file>` | <rejected by> |`, however prettier has padded it.
    ROW = re.compile(r"^\|\s*`negative/([^`]+)`\s*\|\s*(.+?)\s*\|\s*$", re.MULTILINE)

    # Phrase -> layer. The cell is prose, so this classifies on the mechanism it
    # names; a cell naming none of them is an error rather than a default.
    LAYERS = {
        "Nix evaluation": "nix",
        "textx parse": "parse",
        "SDocValidator": "validator",
    }

    DOCUMENT = "[DOCUMENT]\nTITLE: Fixture\n\n[GRAMMAR]\nIMPORT_FROM_FILE: g.sgra\n"


    def expected_layers(readme: pathlib.Path) -> dict[str, str]:
        """The table, as {filename: layer}. An unclassifiable cell is fatal."""
        table = {}
        for name, cell in ROW.findall(readme.read_text(encoding="utf-8")):
            named = [layer for phrase, layer in LAYERS.items() if phrase in cell]
            if len(named) != 1:
                raise SystemExit(
                    f"fixtures/README.md: row for {name!r} names "
                    f"{len(named)} known layers in {cell!r}; expected exactly one"
                )
            table[name] = named[0]
        return table


    def parses(path: pathlib.Path) -> tuple[bool, str]:
        """Does a BARE read accept it? SDocValidator never runs here."""
        try:
            SDocGrammarReader.read(path.read_text(encoding="utf-8"), file_path=str(path))
        except Exception as error:  # noqa: BLE001 - any rejection counts
            return False, f"{type(error).__name__}: {str(error).splitlines()[0]}"
        return True, ""


    def exports(sgra: pathlib.Path, work: pathlib.Path, slug: str) -> tuple[bool, str]:
        """Does a clean-directory whole-corpus export accept it?"""
        project = work / f"project-{slug}"
        project.mkdir(parents=True)
        shutil.copyfile(sgra, project / "g.sgra")
        (project / "d.sdoc").write_text(DOCUMENT, encoding="utf-8")
        done = subprocess.run(
            [
                "strictdoc",
                "export",
                str(project),
                "--formats=json",
                "--output-dir",
                str(work / f"out-{slug}"),
            ],
            capture_output=True,
            text=True,
            cwd=work,
            check=False,
        )
        if done.returncode == 0:
            return True, ""
        # strictdoc reports the failure some way up its own progress output, so
        # the LAST line is usually noise. And it frames EVERY rejection --
        # SDocValidator's included -- as `error: could not parse file`, with the
        # real diagnostic on the next line, so the generic line is the least
        # useful of the ones matching "error". Prefer the specific one.
        lines = [
            line.strip()
            for line in (done.stderr + done.stdout).splitlines()
            if line.strip()
        ]
        for phrase in ("semantic error", "error"):
            diagnostic = [line for line in lines if phrase in line.lower()]
            if diagnostic:
                return False, diagnostic[0]
        return False, lines[-1] if lines else f"exit {done.returncode}"


    def main() -> int:
        manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
        work = pathlib.Path(sys.argv[2])
        negative = pathlib.Path(manifest["negativeDir"])

        expected = expected_layers(pathlib.Path(manifest["readme"]))
        present = {p.name for p in negative.iterdir() if p.is_file()}

        failures: list[str] = []

        undocumented = sorted(present - set(expected))
        if undocumented:
            failures.append(
                "fixtures present but absent from README.md's table: "
                + ", ".join(undocumented)
            )
        missing = sorted(set(expected) - present)
        if missing:
            failures.append(
                "README.md's table names fixtures that do not exist: " + ", ".join(missing)
            )

        print("== positive controls ==")
        if manifest["nixControlAccepted"]:
            print("  ok: a valid element renders at Nix evaluation")
        else:
            failures.append(
                "the VALID control element was rejected at Nix evaluation -- "
                "the Nix arm rejects everything and proves nothing"
            )

        valid = pathlib.Path(manifest["validGrammar"])
        valid_parsed, why = parses(valid)
        if valid_parsed:
            print(f"  ok: {valid.name} parses")
        else:
            failures.append(f"the VALID control grammar failed a bare parse: {why}")
        valid_exported, why = exports(valid, work, "control")
        if valid_exported:
            print(f"  ok: {valid.name} exports cleanly through the same harness")
        else:
            failures.append(
                f"the VALID control grammar failed the export harness: {why} -- "
                "every rejection below is the harness, not the fixture"
            )

        print("== negative fixtures ==")
        for name in sorted(present):
            layer = expected.get(name)
            if layer is None:
                continue  # already reported as undocumented
            path = negative / name
            slug = re.sub(r"[^a-z0-9-]", "-", name.lower())

            if layer == "nix":
                accepted = manifest["nixAccepted"].get(name)
                if accepted is None:
                    failures.append(
                        f"{name}: README.md says Nix evaluation, but it is not a .nix "
                        "fixture and was never evaluated"
                    )
                elif accepted:
                    failures.append(f"{name}: ACCEPTED at Nix evaluation")
                else:
                    print(f"  ok  {name:<38s} rejected at Nix evaluation")
                continue

            parsed, parse_why = parses(path)
            exported, export_why = exports(path, work, slug)

            if layer == "parse":
                if parsed:
                    failures.append(f"{name}: the textx parse ACCEPTED it")
                    continue
                if exported:
                    failures.append(
                        f"{name}: rejected by the parse but EXPORTED cleanly -- impossible"
                    )
                    continue
                print(f"  ok  {name:<38s} rejected at the textx parse ({parse_why})")
            elif layer == "validator":
                if not parsed:
                    failures.append(
                        f"{name}: README.md says SDocValidator, but the bare parse "
                        f"rejected it first ({parse_why}) -- it proves the wrong layer"
                    )
                    continue
                if exported:
                    failures.append(f"{name}: parsed AND exported cleanly")
                    continue
                print(f"  ok  {name:<38s} parses, rejected at export ({export_why})")

        if failures:
            print("\nnegative fixtures: FAILED", file=sys.stderr)
            for failure in failures:
                print(f"  FAIL: {failure}", file=sys.stderr)
            return 1
        print(f"\nnegative fixtures: {len(present)}/{len(present)} rejected at the documented layer")
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
  pkgs.runCommand "strictdoc-grammar-negative-fixtures" {
    nativeBuildInputs = [
      pkgs.ai.devTools.strictdoc
      pkgs.ai.devTools.strictdoc-grammar-extract
    ];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    export HOME="$TMPDIR"
    export PYTHONDONTWRITEBYTECODE=1

    mkdir -p "$TMPDIR/work"
    strictdoc-grammar-extract ${script} ${manifest} "$TMPDIR/work" | tee "$out"
  ''

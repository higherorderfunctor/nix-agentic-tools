# Manual review derivation. mutmut runs its generated changes, then pytest runs the named faults.
# `mutants` and `faults` rerun only the named generated mutants and named fault rows; an empty
# list selects none. Leave both unset for the full pass.
# cspell:ignore conftest TZDIR
{
  pkgs,
  mutants ? null,
  faults ? null,
}: let
  inherit (pkgs) lib;
  # `null` means every mutant, which `mutmut run` takes as an empty argument list.
  mutantNames =
    if mutants == null
    then []
    else mutants;
  inherit (pkgs.ai.generic) python-stack;
  mutmut = python-stack.pkgs.toPythonModule (pkgs.mutmut.override {
    python3Packages = python-stack.pkgs // {inherit (pkgs.python3Packages) textual;};
  });
  python = python-stack.withPackages (ps: [ps.pydantic ps.pytest ps.urllib3 mutmut]);
in
  assert mutmut.version == "3.8.1";
    pkgs.runCommand "credential-usage-mutation" {
      nativeBuildInputs = [pkgs.bash pkgs.pyright python];
      PYTEST_DISABLE_PLUGIN_AUTOLOAD = "1";
      PYTHONDONTWRITEBYTECODE = "1";
      READER_ENTRY = "claude_code.usage.cli:main";
      READER_PAIR = ../../claude-code/usage/cases;
      TZDIR = "${pkgs.tzdata}/share/zoneinfo";
      USAGE_DOC = ../docs/credential-usage.md;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # stdenv sets UTC before running this command.
      export TZ=America/Denver
      pyright --pythonpath "$(command -v python3)" ${./mutation/run.py} ${./mutation/conftest.py}

      mkdir -p claude_code/usage cliproxyapi/usage tests "$out"
      cp -R ${../python/credential_usage} credential_usage
      cp ${../../claude-code/usage}/*.py claude_code/usage/
      cp ${../../cliproxyapi/usage/transport.py} cliproxyapi/usage/transport.py
      cp -R ${./contract} tests/contract
      cp -R ${./conformance} tests/conformance
      cp ${./mutation/conftest.py} tests/conftest.py
      cp ${./mutation/pyproject.toml} pyproject.toml
      chmod -R u+w claude_code cliproxyapi credential_usage tests
      export MATRIX_FILE="$out/matrix.tsv"
      printf 'mutant\ttest\tfixture\tphase\toutcome\n' > "$MATRIX_FILE"

      ${lib.optionalString (mutants != []) "mutmut run --max-children 2 ${lib.escapeShellArgs mutantNames}"}
      mutmut results --all true > "$out/generated.txt"
      while read -r mutant status; do
        if [[ $status != killed && $status != "not checked" ]]; then
          mutmut show "''${mutant%:}"
        fi
      done < "$out/generated.txt" > "$out/surviving-diffs.txt"

      NAMED_FAULT=baseline python3 -B -m pytest -q
      python3 -I -B ${./mutation/run.py} ${./mutation/faults.tsv} "$out/named.tsv" ${
        lib.optionalString (faults != null) "--selection ${lib.escapeShellArg (lib.concatStringsSep "," (map toString faults))}"
      }
    ''

#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Exports the StrictDoc corpus and maps it onto a contract candidate.
#
#   ./export-candidate.sh --out candidate.json
#   ./export-candidate.sh --out - --created N0 N1
#
# Run it inside the fixture shell, which is where strictdoc lives:
#
#   cd <fixture root>
#   devenv shell -- contract/gate2/dsl-review/backend/export-candidate.sh --out -
#
# The script does not invoke `devenv shell` itself, because every other fixture
# command is documented as being run from inside that shell.
#
# strictdoc takes its input path as the PROJECT ROOT, and the grammar import
# `@repo` is resolved from that root's strictdoc_config.py. Handing strictdoc the
# documents directory therefore aborts with `KeyError: '@repo'`, which reads like
# a format problem and is a path problem.
#
# So --project accepts the project root or any directory inside it, and strictdoc
# is given the nearest ancestor holding a strictdoc config. Naming `documents`
# exports the same corpus as naming the root, because `include_doc_paths` already
# narrows the export to `documents/**` and `grammar.sgra`. The resolved root is
# printed whenever it is not the directory that was named, so a walk up is never
# silent, and a path with no such ancestor is refused rather than guessed at.
#
# strictdoc writes into a temporary directory that is removed on exit, so no run
# leaves a file anywhere under the fixture tree. Its progress output goes to
# standard error, so `--out -` writes the candidate alone to standard output.

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
packet="$(cd -- "$here/.." && pwd)"
project="$(cd -- "$packet/../../.." && pwd)"
bundle="$packet/bundle.json"
out=""
created=()

usage() {
  cat <<'USAGE'
Usage: export-candidate.sh --out PATH [--project DIR] [--bundle PATH]
                           [--created UID ...]

  --out PATH      Write the candidate here. - writes to standard output.
  --project DIR   StrictDoc project root, or any directory inside it, such as
                  documents. Defaults to the fixture root.
  --bundle PATH   Bundle naming the model and its grammar. Defaults to the
                  packet bundle.json.
  --created UID   Uids newly allocated during this batch. Repeatable. The
                  default is an empty created list.
USAGE
}

while (($# > 0)); do
  case "$1" in
  --out)
    out="$2"
    shift 2
    ;;
  --project)
    project="$2"
    shift 2
    ;;
  --bundle)
    bundle="$2"
    shift 2
    ;;
  --created)
    shift
    while (($# > 0)) && [[ $1 != --* ]]; do
      created+=("$1")
      shift
    done
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'export-candidate: unknown argument %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if [[ -z $out ]]; then
  printf 'export-candidate: --out is required; pass - for standard output\n' >&2
  usage >&2
  exit 2
fi

if [[ ! -d $project ]]; then
  printf 'export-candidate: no such directory %s\n' "$project" >&2
  exit 2
fi
named="$(cd -- "$project" && pwd)"
root="$named"
while [[ ! -f $root/strictdoc_config.py && ! -f $root/strictdoc.toml ]]; do
  parent="$(dirname -- "$root")"
  if [[ $parent == "$root" ]]; then
    printf 'export-candidate: no strictdoc_config.py or strictdoc.toml at or above %s, so there is no project to export\n' \
      "$named" >&2
    exit 2
  fi
  root="$parent"
done
if [[ $root != "$named" ]]; then
  printf 'export-candidate: %s lies inside the StrictDoc project at %s; exporting that project\n' \
    "$named" "$root" >&2
fi

export_directory="$(mktemp -d)"
trap 'rm -rf -- "$export_directory"' EXIT

(cd -- "$root" && strictdoc export --formats=json --output-dir "$export_directory" .) >&2

arguments=(
  --export "$export_directory/json/index.json"
  --bundle "$bundle"
  --out "$out"
)
if ((${#created[@]} > 0)); then
  arguments+=(--created "${created[@]}")
fi

PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m sdoc_semantics.export "${arguments[@]}"

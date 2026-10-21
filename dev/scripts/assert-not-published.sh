#!/usr/bin/env bash
# Asserts that no store path given as an argument is fetchable from the
# binary cache at $CACHE: the outcome check behind a pushFilter, which is only
# configuration. ci.yml's patched-Kiro and CodeQL-bundle tripwires each
# enumerate their own paths and call this; test-ci-packages.py runs it through
# the Kiro step with mocked services.
#
# Every assertion is "the answer was not 200", which a wrong host or an
# empty argument list would satisfy unconditionally, so both fail closed: the
# cache's nix-cache-info must answer first, and at least one path is
# required. Only a 404 proves absence; a transient 000 or a 5xx fails.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

: "${CACHE:?set CACHE to the binary cache URL}"
if [ "$#" -eq 0 ]; then
  echo "::error::no store paths given, so there is nothing to assert" >&2
  exit 1
fi
if ! curl --fail --silent --show-error "$CACHE/nix-cache-info" >/dev/null; then
  echo "::error::positive control failed: $CACHE is unreachable, so the checks below prove nothing" >&2
  exit 1
fi

failed=0
for path in "$@"; do
  name="${path##*/}"
  hash="${name%%-*}"
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "$CACHE/${hash}.narinfo")"
  case "$code" in
  404) echo "ok (absent): $name" ;;
  200)
    echo "::error::PUBLISHED: $path"
    failed=$((failed + 1))
    ;;
  *)
    echo "::error::inconclusive HTTP $code for $name, treating as failure"
    failed=$((failed + 1))
    ;;
  esac
done

if [ "$failed" -ne 0 ]; then
  echo "::error::${failed} path(s) failed the not-published assertion against $CACHE." \
    "Check the cachix-action pushFilter in ci.yml and update.yml and ci-packages.py's EXCLUDED set." >&2
  exit 1
fi
echo "No asserted path is fetchable from $CACHE."

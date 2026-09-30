{
  lib,
  pkgs,
  ...
}: let
  rv = import ../../lib/runtime-values {inherit lib;};
  reader = lib.getExe (rv.reader pkgs);
  consumer = pkgs.writeShellScript "runtime-value-consumer" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${rv.export {
      inherit pkgs;
      variable = "TOKEN";
      value = rv.file {path = "value";};
    }}
    printf '%s' "$TOKEN" > delivered
    touch reached
  '';
in {
  checks.runtime-values-reader = pkgs.runCommand "runtime-values-reader" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    read_value() { ${reader} test.option "$@"; }
    reject() {
      if read_value "$@" >out 2>diagnostic; then
        echo 'unexpected reader success' >&2
        exit 1
      fi
      test ! -s out
      grep -F 'test.option:' diagnostic
      if grep -F 'DO-NOT-LEAK' diagnostic; then exit 1; fi
    }
    reject file missing
    mkdir directory
    reject file directory
    touch empty
    reject file empty
    printf 'DO-NOT-LEAK' > unreadable
    chmod 000 unreadable
    reject file unreadable
    cat > helper <<'HELPER'
    #!${pkgs.bash}/bin/bash
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf DO-NOT-LEAK
    printf DO-NOT-LEAK >&2
    exit 7
    HELPER
    chmod +x helper
    reject helper "$PWD/helper"
    printf 'bad\000bytes' > nul
    reject file nul
    printf 'value\n\n' > value
    ${consumer}
    printf value > expected
    cmp expected delivered
    test -e reached
    rm reached
    : > value
    if ${consumer} >out 2>diagnostic; then exit 1; fi
    test ! -e reached
    touch "$out"
  '';
}

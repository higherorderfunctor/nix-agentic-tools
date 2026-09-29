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
      value = rv.file {
        path = "value";
        newline = "preserve";
      };
    }}
    printf '%s' "$TOKEN" > delivered
    touch reached
  '';
in {
  checks.runtime-values-reader = pkgs.runCommand "runtime-values-reader" {} ''
    read_value() { ${reader} test.option "$@"; }
    reject() {
      if read_value "$@" >out 2>diagnostic; then echo 'unexpected reader success' >&2; exit 1; fi
      test ! -s out
      grep -F 'test.option:' diagnostic
      if grep -F 'DO-NOT-LEAK' diagnostic; then exit 1; fi
    }
    reject file missing strip-final-lf "" ""
    mkdir directory
    reject file directory strip-final-lf "" ""
    touch empty
    reject file empty strip-final-lf "" ""
    printf 'DO-NOT-LEAK' > unreadable
    chmod 000 unreadable
    reject file unreadable strip-final-lf "" ""
    cat > helper <<'HELPER'
    #!${pkgs.bash}/bin/bash
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf DO-NOT-LEAK
    printf DO-NOT-LEAK >&2
    exit 7
    HELPER
    chmod +x helper
    reject helper "$PWD/helper" strip-final-lf "" ""
    printf 'value\n\n' > value
    printf 'value\n' > expected
    read_value file value strip-final-lf "" "" > actual
    cmp expected actual
    read_value file value preserve "" "" > actual
    cmp value actual
    printf '<value\n>' > expected
    read_value file value strip-final-lf '<' '>' > actual
    cmp expected actual
    printf 'not-a-bool' > bad-type
    reject file bad-type preserve "" "" bool
    printf 'bad\000bytes' > nul
    reject file nul preserve "" ""
    printf '\377' > invalid-utf8
    reject file invalid-utf8 preserve "" ""
    ${consumer}
    cmp value delivered
    test -e reached
    rm reached
    : > value
    if ${consumer} >out 2>diagnostic; then exit 1; fi
    test ! -e reached
    touch "$out"
  '';
}

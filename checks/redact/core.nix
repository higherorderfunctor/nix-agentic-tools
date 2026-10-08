{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  redact = self.lib.redact;
  evaluate = type: definitions:
    (lib.evalModules {
      modules = [{options.value = lib.mkOption {inherit type;};}] ++ map (value: {inherit value;}) definitions;
    }).config.value;
  accepts = type: value: (builtins.tryEval (builtins.deepSeq (evaluate type [value]) true)).success;
  file = redact.file {path = "/run/secrets/token";};
  command = redact.command {path = "/run/current-system/sw/bin/read-token";};
  reader = lib.getExe (redact.reader pkgs);
  consumer = pkgs.writeShellScript "redact-reader-consumer" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${redact.read {
      inherit pkgs;
      value = redact.file {path = "/nonexistent/redact-secret";};
      option = "test.token";
      target = "TOKEN";
      export = true;
    }}
    printf 'consumer executed\n'
  '';
in {
  checks.redact-types = harness.mkTest "redact-types" (
    assert accepts redact.types.redacted file;
    assert accepts redact.types.redacted command;
    assert !(accepts redact.types.redacted "literal-secret");
    assert !(accepts redact.types.redacted (redact.file {path = ./core.nix;}));
    assert !(accepts redact.types.redacted (redact.file {path = "${./core.nix}";}));
    assert !(accepts redact.types.redacted {
      _redact = {
        file = "/a";
        command = "/b";
      };
    });
    assert accepts (redact.types.maybeRedacted lib.types.str) "public-host";
    assert accepts (redact.types.maybeRedacted lib.types.str) file;
    assert accepts (redact.types.maybeRedacted (lib.extend (_: _: {})).types.str) "public-host";
    assert !(accepts (redact.types.maybeRedacted lib.types.str) false);
    assert accepts redact.types.environment {
      TOKEN = file;
      EDITOR = "vim";
    };
    assert !(accepts redact.types.environment {TOKEN = "literal-secret";});
    assert evaluate redact.types.environment [{TOKEN = "discarded";} {TOKEN = lib.mkForce file;}] == {TOKEN = file;};
    assert evaluate redact.types.environment [{TOKEN = file;} {TOKEN = lib.mkForce null;}] == {TOKEN = null;}; true
  );
  checks.redact-reader = pkgs.runCommand "redact-reader" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export LC_ALL=C
    # Build-only fixture: its bytes are absent from the reader and consumer plans.
    sentinel="redact-$(cat /proc/sys/kernel/random/uuid)"
    printf '%s\n\n' "$sentinel" > value
    test "$(${reader} test.token file "$PWD/value")" = "$sentinel"
    printf 'quote" slash\\ internal\nnewline\n' > value
    ${reader} test.token file "$PWD/value" > actual
    printf 'quote" slash\\ internal\nnewline' > expected
    cmp actual expected
    : > empty
    printf '%s\0value' "$sentinel" > nul
    mkdir directory
    for input in empty nul directory absent; do
      if ${reader} test.token file "$PWD/$input" >captured.out 2>captured.err; then
        exit 1
      fi
      test ! -s captured.out
      grep -q '^test.token:' captured.err
      if grep -Fq "$sentinel" captured.err; then echo "leak: reader diagnostics" >&2; exit 1; fi
    done
    cat > noisy <<'SCRIPT'
    #!${pkgs.runtimeShell}
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf '%s' "$NOISY_VALUE"
    printf '%s' "$NOISY_VALUE" >&2
    exit 1
    SCRIPT
    chmod +x noisy
    export NOISY_VALUE="$sentinel"
    if ${reader} test.token command "$PWD/noisy" >captured.out 2>captured.err; then
      exit 1
    fi
    test ! -s captured.out
    grep -q '^test.token: reference command failed$' captured.err
    if grep -Fq "$sentinel" captured.err; then echo "leak: reader diagnostics" >&2; exit 1; fi
    if ${consumer} >captured.out 2>captured.err; then
      exit 1
    fi
    test ! -s captured.out
    grep -q '^test.token:' captured.err
    touch "$out"
  '';
}

# cspell:ignore urandom
# The reader at launch, with a sentinel that exists only at build time: each
# failure aborts, names the label and never echoes the value or a command's
# output; a concat joins its parts; `assign` aborts its consumer on its own.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.lib) redact;
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  strict = import ../../lib/strict-shell-application.nix pkgs;
  reader = lib.getExe (import ../../lib/redact/reader.nix {inherit pkgs;});
  fixture = name: text: strict {inherit name text;};
  # Commands print the build-time sentinel the check exports.
  fixtures = {
    empty = fixture "redact-empty" ":";
    noisy = fixture "redact-noisy" ''
      printf '%s\n' "$REDACT_SENTINEL"
      printf '%s\n' "$REDACT_SENTINEL" >&2
      exit 1
    '';
    nul = fixture "redact-nul" ''printf '%s\0tail' "$REDACT_SENTINEL"'';
    ok = fixture "redact-ok" ''printf '%s\n\n' "$REDACT_SENTINEL"'';
  };
  # A store command carries context, which redact refuses. A path with the
  # context discarded is not a runtime dependency, so the check's runtimeInputs
  # keep the fixtures alive instead.
  command = name: redact.command (builtins.unsafeDiscardStringContext (lib.getExe fixtures.${name}));
  consumer = name: value: export: body:
    strict {
      inherit name;
      text = ''
        # The emitted shell must abort without the caller's errexit.
        set +o errexit
        ${redact.assign {
          inherit export pkgs value;
          option = "test.token";
          variable = "REDACT_VALUE";
        }}
        ${body}
      '';
    };
  exported = consumer "redact-exported" (redact.concat ["Bearer " (command "ok")]) true ''
    ${pkgs.coreutils}/bin/printenv REDACT_VALUE
  '';
  local = consumer "redact-local" (command "ok") false ''
    printf '%s' "$REDACT_VALUE"
    if ${pkgs.coreutils}/bin/printenv REDACT_VALUE; then exit 1; fi
  '';
  aborted = consumer "redact-aborted" (redact.concat [(command "noisy") "tail"]) true ''
    printf 'consumer continued\n'
  '';
in {
  checks.redact-runtime = mkLintedCheck "redact-runtime" {
    runtimeInputs = builtins.attrValues fixtures;
    text = ''
      REDACT_SENTINEL="redact-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      export REDACT_SENTINEL
      leaks() { grep -qF "$REDACT_SENTINEL" "$@"; }
      # A failing read prints nothing on stdout and one labelled line on stderr.
      refuses() {
        local expected=$1
        shift
        if ${reader} test.token "$@" >read.out 2>read.err; then
          printf 'FAIL: accepted %s\n' "$*" >&2
          exit 1
        fi
        [[ ! -s read.out ]] || { echo "FAIL: output on refusal: $*" >&2; exit 1; }
        [[ "$(<read.err)" == "test.token: $expected" ]] || {
          printf 'FAIL: %s: unexpected diagnostics\n' "$*" >&2
          exit 1
        }
        if leaks read.err; then echo "FAIL: leak: $*" >&2; exit 1; fi
      }

      # Trailing newlines go; internal ones and shell metacharacters stay.
      printf '%s\n\n' "$REDACT_SENTINEL" >value
      ${reader} test.token file "$PWD/value" >actual
      printf '%s' "$REDACT_SENTINEL" >expected
      cmp actual expected
      printf 'quote" slash\\ internal\nnewline\n' >special
      ${reader} test.token file "$PWD/special" >actual
      printf 'quote" slash\\ internal\nnewline' >expected
      cmp actual expected

      : >empty
      printf '\n\n' >newlines
      printf '%s\0tail' "$REDACT_SENTINEL" >nul
      mkdir directory
      refuses 'reference file is missing' file "$PWD/absent"
      refuses 'reference is a directory' file "$PWD/directory"
      refuses 'reference resolved empty' file "$PWD/empty"
      refuses 'reference resolved empty' file "$PWD/newlines"
      refuses 'reference contains a NUL byte' file "$PWD/nul"
      printf '%s' "$REDACT_SENTINEL" >unreadable
      chmod 000 unreadable
      # Root reads any file, so only an unprivileged builder can see this case.
      if [[ ! -r unreadable ]]; then
        refuses 'reference file is unreadable' file "$PWD/unreadable"
      fi

      ${reader} test.token command ${lib.getExe fixtures.ok} >actual
      printf '%s' "$REDACT_SENTINEL" >expected
      cmp actual expected
      refuses 'reference command failed' command ${lib.getExe fixtures.noisy}
      refuses 'reference command failed' command "$PWD/absent"
      refuses 'reference resolved empty' command ${lib.getExe fixtures.empty}
      # A NUL may stop the read before the command exits; either refusal aborts.
      if ${reader} test.token command ${lib.getExe fixtures.nul} >read.out 2>read.err; then
        echo 'FAIL: accepted a NUL from a command' >&2
        exit 1
      fi
      [[ ! -s read.out ]]
      if leaks read.err; then echo 'FAIL: leak: NUL command' >&2; exit 1; fi

      # A concat joins literal and read parts, and prints nothing when one fails.
      ${reader} test.token literal 'Bearer ' file "$PWD/value" literal / command ${lib.getExe fixtures.ok} >actual
      printf 'Bearer %s/%s' "$REDACT_SENTINEL" "$REDACT_SENTINEL" >expected
      cmp actual expected
      refuses 'reference file is missing' literal 'Bearer ' file "$PWD/value" file "$PWD/absent"

      # assign: exported to children, kept local without export, and aborting.
      [[ "$(${lib.getExe exported})" == "Bearer $REDACT_SENTINEL" ]]
      [[ "$(${lib.getExe local})" == "$REDACT_SENTINEL" ]]
      if ${lib.getExe aborted} >consumer.out 2>consumer.err; then
        echo 'FAIL: consumer continued after a failed read' >&2
        exit 1
      fi
      [[ ! -s consumer.out ]]
      [[ "$(<consumer.err)" == 'test.token: reference command failed' ]]
      if leaks consumer.out consumer.err; then echo 'FAIL: leak: consumer' >&2; exit 1; fi
    '';
  };
}

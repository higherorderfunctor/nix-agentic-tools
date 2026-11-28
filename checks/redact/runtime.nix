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
    # Write nothing after the NUL, so the reader closing the pipe at the NUL
    # cannot turn this successful command into a write failure.
    nul = fixture "redact-nul" ''printf '%s\0' "$REDACT_SENTINEL"'';
    ok = fixture "redact-ok" ''printf '%s\n\n' "$REDACT_SENTINEL"'';
  };
  command = name: redact.command (lib.getExe fixtures.${name});
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
  childValue = "${pkgs.coreutils}/bin/printenv REDACT_VALUE";
  exported = consumer "redact-exported" (redact.concat ["Bearer " (command "ok")]) true childValue;
  literal = consumer "redact-literal" "it's $(printf changed)" true childValue;
  local = consumer "redact-local" (command "ok") false remainsLocal;
  localLiteral = consumer "redact-local-literal" "local text" false remainsLocal;
  remainsLocal = ''
    printf '%s' "$REDACT_VALUE"
    if ${pkgs.coreutils}/bin/printenv REDACT_VALUE; then exit 1; fi
  '';
  aborted = consumer "redact-aborted" (redact.concat [(command "noisy") "tail"]) true ''
    printf 'consumer continued\n'
  '';
in {
  checks.redact-runtime = mkLintedCheck "redact-runtime" {
    text = ''
      REDACT_SENTINEL="redact-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      export REDACT_SENTINEL
      unset REDACT_VALUE
      # A failure exits 1, prints nothing on stdout and names a permitted reason.
      refuses() {
        local reason=$1 status=0
        shift
        "$@" >read.out 2>read.err || status=$?
        if grep -qF "$REDACT_SENTINEL" read.out read.err; then echo "FAIL: leak: $*" >&2; exit 1; fi
        [[ $status == 1 ]] || { printf 'FAIL: %s exited %s, expected 1\n' "$*" "$status" >&2; exit 1; }
        [[ ! -s read.out ]] || { echo "FAIL: output on refusal: $*" >&2; exit 1; }
        cmp -s read.err <(printf 'test.token: %s\n' "$reason") || {
          printf 'FAIL: %s did not report %s\n' "$*" "$reason" >&2
          exit 1
        }
      }
      reader_refuses() {
        local expected=$1
        shift
        refuses "$expected" ${reader} test.token "$@"
      }

      # Match bytes, not command substitution (which would hide extra newlines).
      produces() {
        local row=$1 expected=$2
        shift 2
        if ! "$@" >actual || ! cmp -s actual <(printf '%s' "$expected"); then
          printf 'FAIL: %s did not produce the expected bytes\n' "$row" >&2
          exit 1
        fi
      }
      reader_produces() {
        local row=$1 expected=$2
        shift 2
        produces "$row" "$expected" ${reader} test.token "$@"
      }

      # Trailing newlines go; internal ones and shell metacharacters stay.
      printf 'file:%s\n\n' "$REDACT_SENTINEL" >value
      printf ' quote" slash\\ internal\nnewline\n\n' >special
      reader_produces 'file preserves spaces, backslash and internal newline while trimming its end' \
        $' quote" slash\\ internal\nnewline' file "$PWD/special"

      # Distinguish a zero-byte file from one that becomes empty after trim.
      : >empty
      printf '\n\n' >newlines
      printf '%s\0tail' "$REDACT_SENTINEL" >nul
      mkdir directory
      reader_refuses 'reference file is missing' file "$PWD/absent"
      reader_refuses 'reference is a directory' file "$PWD/directory"
      reader_refuses 'reference resolved empty' file "$PWD/empty"
      reader_refuses 'reference resolved empty' file "$PWD/newlines"
      reader_refuses 'reference contains a NUL byte' file "$PWD/nul"
      printf '%s' "$REDACT_SENTINEL" >unreadable
      chmod 000 unreadable
      # Root reads any file, so only an unprivileged builder can see this case.
      if [[ ! -r unreadable ]]; then
        reader_refuses 'reference file is unreadable' file "$PWD/unreadable"
      fi

      # A program can exit unsuccessfully after printing a usable-looking
      # value, or fail to start at all; neither case may publish output.
      reader_refuses 'reference command failed' command ${lib.getExe fixtures.noisy}
      reader_refuses 'reference command failed' command "$PWD/absent"
      reader_refuses 'reference resolved empty' command ${lib.getExe fixtures.empty}
      reader_refuses 'reference contains a NUL byte' command ${lib.getExe fixtures.nul}

      # A concat joins literal and read parts, and prints nothing when one fails.
      reader_produces 'concat keeps the order of literals, file and command' \
        "Bearer file:$REDACT_SENTINEL/$REDACT_SENTINEL" \
        literal 'Bearer ' file "$PWD/value" literal / command ${lib.getExe fixtures.ok}
      reader_refuses 'reference file is missing' literal 'Bearer ' file "$PWD/value" file "$PWD/absent"

      # assign: exported to children, kept local without export, and aborting.
      produces 'concat reaches a child process only via export' \
        "Bearer $REDACT_SENTINEL"$'\n' ${lib.getExe exported}
      produces 'a reference without export is local to the launcher' "$REDACT_SENTINEL" ${lib.getExe local}
      produces 'an exported literal keeps the apostrophe without running substitution' \
        "it's \$(printf changed)"$'\n' ${lib.getExe literal}
      produces 'a literal without export is local to the launcher' 'local text' ${lib.getExe localLiteral}
      # Without errexit the launcher would continue unless assign aborts it.
      refuses 'reference command failed' ${lib.getExe aborted}
    '';
  };
}

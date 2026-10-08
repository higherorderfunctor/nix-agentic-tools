{
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  command = body:
    redact.command {
      path = toString (pkgs.writeShellScript "glab-test-reader" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${body}
      '');
    };
  host = command ''printf '%s' "$GLAB_TEST_HOST"'';
  token = command ''printf '%s' "$GLAB_TEST_TOKEN"'';
  noisy = command ''
    printf '%s' "$GLAB_TEST_TOKEN"
    printf '%s' "$GLAB_TEST_TOKEN" >&2
    exit 19
  '';
  stub = (pkgs.writeShellScriptBin "glab" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf '%s\n' "$@" >> "$GLAB_TEST_ARGV"
    test "$GITLAB_HOST" = "$GLAB_TEST_HOST"
    if [ "$1" = auth ]; then
      test "$GIT_DIR" = /dev/null
      test "$(< /dev/stdin)" = "$GLAB_TEST_TOKEN"
      # Real glab may include the hostname in its login status.
      printf '%s\n' "$GITLAB_HOST" >&2
    else
      test "$GITLAB_TOKEN" = "$GLAB_TEST_TOKEN"
    fi
  '').overrideAttrs (_: {version = "0-test";});
  base = {
    configDir = "glab-redact-config";
    extraSettings = {};
    inherit host token;
    package = stub;
    settings = {};
  };
  wrapped = cfg: import ../lib/mkGlab.nix {inherit cfg lib pkgs;};
  good = wrapped (base // {token = redact.file {path = "/dev/stdin";};});
  bad = wrapped (base // {token = noisy;});
  sync = import ../lib/mkKeyringSync.nix {
    cfg = base;
    configDir = "glab-redact-sync";
    inherit lib;
    pendingFile = "pending";
    pkgs =
      pkgs
      // {
        libsecret = pkgs.writeShellScriptBin "secret-tool" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          if [ "$1" = store ]; then
            test "$(< /dev/stdin)" = probe
          fi
        '';
      };
  };
  plan = pkgs.writeText "glab-redact-plan.json" (builtins.toJSON {
    invocation = good.wrapperText;
    noisy = bad.wrapperText;
    synchronization = sync.scriptText;
  });
in {
  checks.glab-redact-runtime = pkgs.runCommand "glab-redact-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    # Generated only inside the sandbox: the store plan cannot know the values.
    export GLAB_TEST_HOST="private-$RANDOM-$RANDOM.invalid"
    export GLAB_TEST_TOKEN="secret-$RANDOM-$RANDOM"
    export GLAB_TEST_ARGV="$PWD/argv"
    : > "$GLAB_TEST_ARGV"
    printf '%s' "$GLAB_TEST_TOKEN" | ${good}/bin/glab version >diagnostics 2>&1
    for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
      if grep -qF -- "$value" ${plan} ${good}/bin/glab "$GLAB_TEST_ARGV" diagnostics; then
        echo 'glab reference leaked into plan, argv or diagnostics' >&2
        exit 1
      fi
    done
    test "$(cat "$GLAB_TEST_ARGV")" = version

    : > "$GLAB_TEST_ARGV"
    if ${bad}/bin/glab version >diagnostics 2>&1; then
      echo 'glab started after a failed reference command' >&2
      exit 1
    fi
    test ! -s "$GLAB_TEST_ARGV"
    grep -F glab.token diagnostics
    if grep -qF -- "$GLAB_TEST_TOKEN" diagnostics; then
      echo 'failed reference command output leaked' >&2
      exit 1
    fi

    touch pending
    ${sync.script} >diagnostics 2>&1
    test ! -e pending
    grep -x -- --stdin "$GLAB_TEST_ARGV"
    for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
      if grep -qF -- "$value" ${plan} "$GLAB_TEST_ARGV" diagnostics; then
        echo 'glab keyring reference leaked into plan, argv or diagnostics' >&2
        exit 1
      fi
    done
    touch "$out"
  '';
}

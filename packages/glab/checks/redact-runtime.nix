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
  syncFor = cfg:
    import ../lib/mkKeyringSync.nix {
      inherit cfg;
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
  sync = syncFor base;
  failedSync = syncFor (base
    // {
      package = pkgs.writeShellScriptBin "glab" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        token="$(< /dev/stdin)"
        printf 'denied: %s %s\n' "$GITLAB_HOST" "$token" >&2
        exit 1
      '';
    });
  referenceOnly =
    lib.all ({
      text,
      target,
    }:
      lib.hasInfix "redact-read" text
      && lib.hasInfix "glab-test-reader" text
      && lib.hasInfix (target + "=\"$(") text
      && builtins.length (lib.splitString "${target}=" text) == 2)
    [
      {
        text = good.wrapperText;
        target = "GITLAB_TOKEN";
      }
      {
        text = bad.wrapperText;
        target = "GITLAB_TOKEN";
      }
      {
        text = sync.scriptText;
        target = "glab_sync_token";
      }
    ]
    && lib.hasInfix "/dev/stdin" good.wrapperText;
in {
  checks = {
    module-glab-keyring-sync-failed-login-redacts-diagnostics = pkgs.runCommand "module-glab-keyring-sync-failed-login-redacts-diagnostics" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export GLAB_TEST_HOST="private-$RANDOM-$RANDOM.invalid"
      export GLAB_TEST_TOKEN="secret-$RANDOM-$RANDOM"
      if ${failedSync.script} >diagnostics 2>&1; then
        echo 'failed keyring login unexpectedly succeeded' >&2
        exit 1
      fi
      grep -F 'login failed: denied: glab.host glab.token' diagnostics
      for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
        if grep -Fq "$value" diagnostics; then echo "leak: failed keyring login diagnostics" >&2; exit 1; fi
      done
      touch "$out"
    '';
    module-glab-keyring-sync-no-pending-marker = pkgs.runCommand "module-glab-keyring-sync-no-pending-marker" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export GLAB_TEST_HOST="private-$RANDOM-$RANDOM.invalid"
      export GLAB_TEST_TOKEN="secret-$RANDOM-$RANDOM"
      export GLAB_TEST_ARGV="$PWD/argv"
      test ! -e pending
      ${sync.script} >diagnostics 2>&1
      test ! -e pending
      grep -x -- --stdin "$GLAB_TEST_ARGV"
      for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
        if grep -Fq "$value" "$GLAB_TEST_ARGV" diagnostics; then echo "leak: keyring without marker" >&2; exit 1; fi
      done
      touch "$out"
    '';
    glab-redact-runtime = assert referenceOnly;
      pkgs.runCommand "glab-redact-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        # Generated only inside the sandbox: the store plan cannot know the values.
        export GLAB_TEST_HOST="private-$RANDOM-$RANDOM.invalid"
        export GLAB_TEST_TOKEN="secret-$RANDOM-$RANDOM"
        export GLAB_TEST_ARGV="$PWD/argv"
        : > "$GLAB_TEST_ARGV"
        printf '%s' "$GLAB_TEST_TOKEN" | ${good}/bin/glab version >diagnostics 2>&1
        for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
          if grep -Fq "$value" "$GLAB_TEST_ARGV" diagnostics; then
            echo 'leak: glab argv or diagnostics' >&2
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
        if grep -Fq "$GLAB_TEST_TOKEN" diagnostics; then
          echo 'leak: glab failed reference diagnostics' >&2
          exit 1
        fi

        touch pending
        ${sync.script} >diagnostics 2>&1
        test ! -e pending
        grep -x -- --stdin "$GLAB_TEST_ARGV"
        for value in "$GLAB_TEST_HOST" "$GLAB_TEST_TOKEN"; do
          if grep -Fq "$value" "$GLAB_TEST_ARGV" diagnostics; then
            echo 'leak: glab keyring argv or diagnostics' >&2
            exit 1
          fi
        done
        touch "$out"
      '';
  };
}

# The activation merge must not widen a credential file.
# cspell:ignore natcreds  (test-scaffold token, not project vocabulary)
#
# `mkSettingsActivationScript` reconciles Nix-declared settings into files the
# runtime itself writes secrets into — `.claude.json` carries account tokens,
# kimchi's `config.json` carries `apiKey` and `gitTokens`. It used to end with a
# hardcoded `chmod 644`, which was the ONLY thing making those files group- and
# world-readable: `mktemp` creates at 0600 and `mv` preserves that mode. Every
# activation silently re-widened them, and nothing failed.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../lib/ai/hm-helpers.nix {inherit lib;};

  mkScript = extra:
    pkgs.writeText "activation-body.sh" (helpers.mkSettingsActivationScript ({
        configFile = ".natcreds/config.json";
        settingsJson = builtins.toJSON {declared = "from-nix";};
        jq = "${pkgs.jq}/bin/jq";
        inherit (pkgs) coreutils;
      }
      // extra));

  defaultBody = mkScript {};
  # Interpose at jq's return: its output already contains the old runtime
  # values, but activation has not renamed that output over the destination.
  racingJq = pkgs.writeShellScript "activation-racing-jq" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.jq}/bin/jq "$@"
    count=0
    if [ -f "$HOME/writes" ]; then
      count=$(${pkgs.coreutils}/bin/cat "$HOME/writes")
    fi
    if [ "$count" -eq 0 ] || [ "$RACE_MODE" = repeated ]; then
      count=$((count + 1))
      target="$HOME/.natcreds/config.json"
      sibling=$(${pkgs.coreutils}/bin/mktemp "$target.writer.XXXXXX")
      printf '{"deviceId":"device-%s","gitTokens":{"host":"token-%s"}}' \
        "$count" "$count" > "$sibling"
      # Same size and timestamp, different content and inode: this models a
      # runtime's sibling-temp rename and discriminates against mtime alone.
      ${pkgs.coreutils}/bin/touch -r "$target" "$sibling"
      ${pkgs.coreutils}/bin/mv "$sibling" "$target"
      printf '%s' "$count" > "$HOME/writes"
    fi
  '';
  racingBody = mkScript {jq = "${racingJq}";};
  wideBody = mkScript {mode = "0644";};
in {
  checks.ai-activation-settings-mode =
    pkgs.runCommandLocal "ai-activation-settings-mode" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.jq];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # Assert the mode of the reconciled file, naming the case on failure so
      # whoever trips this learns which property broke rather than just "600".
      assert_mode() { # $1 = home, $2 = expected, $3 = case label
        local got
        got=$(stat -c %a "$1/.natcreds/config.json")
        if [ "$got" != "$2" ]; then
          echo "FAIL [$3]: expected mode $2, got $got" >&2
          echo "  file: $1/.natcreds/config.json" >&2
          exit 1
        fi
      }

      # 1. A file the activation CREATES must not be world-readable.
      h1="$PWD/h1"; mkdir -p "$h1"
      HOME="$h1" ${pkgs.bash}/bin/bash ${defaultBody}
      assert_mode "$h1" 600 "newly created file"

      # 2. The regression itself: an EXISTING 0600 credential file must keep
      #    its mode, and must still be merged rather than clobbered.
      h2="$PWD/h2"; mkdir -p "$h2/.natcreds"
      printf '{"apiKey":"secret"}' > "$h2/.natcreds/config.json"
      chmod 600 "$h2/.natcreds/config.json"
      HOME="$h2" ${pkgs.bash}/bin/bash ${defaultBody}
      assert_mode "$h2" 600 "existing credential file must not be widened"
      if ! ${pkgs.jq}/bin/jq -e '.apiKey == "secret" and .declared == "from-nix"' \
           "$h2/.natcreds/config.json" > /dev/null; then
        echo "FAIL: merge lost the runtime value or the declared value" >&2
        exit 1
      fi

      # 3. Discrimination. If `mode` were inert, cases 1 and 2 would pass no
      #    matter what the helper did, so this proves the knob is live and the
      #    assertion can tell 600 from 644.
      h3="$PWD/h3"; mkdir -p "$h3"
      HOME="$h3" ${pkgs.bash}/bin/bash ${wideBody}
      assert_mode "$h3" 644 "explicit mode must be honoured"

      # 4. One racing write must survive a successful retry. Continuous
      #    writes must exhaust the bound loudly without replacing runtime data.
      for race in once repeated; do
        race_home="$PWD/race-$race"
        mkdir -p "$race_home/.natcreds"
        printf '{"deviceId":"device-0","gitTokens":{"host":"token-0"}}' \
          > "$race_home/.natcreds/config.json"
        chmod 600 "$race_home/.natcreds/config.json"
        status=0
        HOME="$race_home" RACE_MODE="$race" \
          timeout 10 ${pkgs.bash}/bin/bash ${racingBody} \
          > "$race_home/activation.log" 2>&1 || status=$?
        writes=$(cat "$race_home/writes")
        if ! jq -e --arg value "$writes" \
          '.deviceId == ("device-" + $value) and .gitTokens.host == ("token-" + $value)' \
          "$race_home/.natcreds/config.json" > /dev/null; then
          echo "FAIL [$race race]: activation lost the concurrent deviceId/gitTokens write" >&2
          false
        fi
        assert_mode "$race_home" 600 "$race race"
        if [ "$race" = once ]; then
          test "$status" -eq 0
          jq -e '.declared == "from-nix"' "$race_home/.natcreds/config.json" > /dev/null
        else
          test "$status" -eq 1
          test "$writes" -eq 3
          expected="settings activation: $race_home/.natcreds/config.json changed during all 3 attempts; refusing to overwrite concurrent runtime changes; retry activation"
          test "$(cat "$race_home/activation.log")" = "$expected"
          jq -e 'has("declared") | not' "$race_home/.natcreds/config.json" > /dev/null
        fi
        test -z "$(find "$race_home/.natcreds" -name 'config.json.activation.*' -print)"
      done

      touch "$out"
    '';
}

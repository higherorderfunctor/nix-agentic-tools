# Behavioral test for packages/kiro-cli/lib/wrapPackage.nix — the argv the
# kiro-cli wrapper actually forwards.
#
# The wrapper makes two argv injections, and POSITION is the correctness
# question for both: the global `--v3` must precede the subcommand (appended,
# clap parses it against the subcommand and rejects it), while `acp`'s own
# `--agent-engine=v3` must follow `acp`. That failure is invisible from the
# Nix side — the generated script is well-formed either way — so this drives
# the REAL wrapper against a stub package that prints its argv.
#
# String-matching the generated bash (packages/kiro-cli/checks/module-eval.nix)
# cannot catch a flag emitted on the wrong side of the subcommand, nor a scan
# that mis-parses `--agent acp` as the `acp` subcommand. Running it can.
{
  lib,
  pkgs,
  ...
}: {
  checks.kiro-wrapper-argv = let
    wrapKiroPackage = (import ../lib/wrapPackage.nix {inherit lib pkgs;}).wrapPackage;

    # Stand-in for the real kiro-cli: prints the argv it received (one ARG line
    # per token, so an empty or space-bearing argument stays unambiguous) plus one
    # baked env var plus PATH lookups, which is how the env-export and
    # extraPackages paths are asserted.
    # `${KIRO_WRAPPER_TEST-unset}` keeps its default so the `-u` in strict mode
    # reports an unbaked env var rather than aborting the stub.
    echoArgv = pkgs.writeShellScript "kiro-cli-stub-argv" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'ENV=%s\n' "''${KIRO_WRAPPER_TEST-unset}"
      printf 'AMBIENT=%s\n' "$(command -v kiro-ambient-sentinel || :)"
      printf 'EXTRA=%s\n' "$(command -v kiro-path-sentinel || :)"
      for nat_a in "$@"; do printf 'ARG=%s\n' "$nat_a"; done
    '';
    ambientSentinel = pkgs.writeShellApplication {
      name = "kiro-ambient-sentinel";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'ambient\n'
      '';
    };
    extraSentinel = pkgs.writeShellApplication {
      name = "kiro-path-sentinel";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'extra\n'
      '';
    };
    stubPackage = pkgs.runCommandLocal "kiro-cli-stub" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin"
      ln -s ${echoArgv} "$out/bin/kiro-cli"
    '';

    wrap = args: wrapKiroPackage ({package = stubPackage;} // args);

    # Nothing configured: the wrapper still exists, for the engine selectors.
    plainWrapped = wrap {};
    # env only: the wrapper exports it and injects the same selectors.
    envWrapped = wrap {environmentVariables.KIRO_WRAPPER_TEST = "baked";};
    # extraPackages only: the wrapper prepends its bins without discarding the
    # caller's PATH.
    pathWrapped = wrap {extraPackages = [extraSentinel];};
  in
    pkgs.runCommandLocal "kiro-wrapper-argv-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      pass=0
      fail=0
      ok() { pass=$((pass + 1)); echo "ok   - $1"; }
      bad() { fail=$((fail + 1)); echo "FAIL - $1" >&2; }

      # argv <bin> [args…] -> the forwarded tokens joined with '|'
      argv() {
        local bin="$1"
        shift
        "$bin" "$@" | sed -n 's/^ARG=//p' | paste -sd'|' -
      }

      # expect <label> <expected> <bin> [args…]
      expect() {
        local label="$1" want="$2" got
        shift 2
        got="$(argv "$@")"
        if [ "$got" = "$want" ]; then
          ok "$label"
        else
          bad "$label: want [$want] got [$got]"
        fi
      }

      V=${plainWrapped}/bin/kiro-cli
      E=${envWrapped}/bin/kiro-cli
      P=${pathWrapped}/bin/kiro-cli

      # ── the global lands BEFORE the subcommand, never after ─────────────────
      # `kiro-cli acp --v3` is "error: unexpected argument found", while
      # `--v3 acp` runs. A string match on the generated bash cannot catch a
      # flag emitted on the wrong SIDE; running it can.
      expect "bare launch"                  '--v3'                      "$V"
      expect "chat keeps it in front"       '--v3|chat'                 "$V" chat
      expect "chat INPUT stays last"        '--v3|chat|hello'           "$V" chat hello
      expect "acp gets --v3 before it and its engine after it" \
        '--v3|acp|--agent-engine=v3'                                      "$V" acp
      expect "mcp gets --v3, before it"     '--v3|mcp|list'             "$V" mcp list
      expect "agent gets --v3, before it"   '--v3|agent|list'           "$V" agent list
      expect "settings gets --v3"           '--v3|settings|all'         "$V" settings all
      expect "whoami gets --v3"             '--v3|whoami'               "$V" whoami
      expect "-- still gets --v3"           '--v3|--'                   "$V" --

      # ── idempotence: a caller's own --v3 is never doubled ───────────────────
      # A repeated `--v3` aborts with "cannot be used multiple times".
      expect "caller's --v3 not doubled"    'chat|--v3'                 "$V" chat --v3
      expect "caller's --v3 on acp"         'acp|--v3|--agent-engine=v3' "$V" acp --v3
      # Exact-token match, not a substring scan of "$*": a prompt that merely
      # mentions the flag must not suppress the real one.
      expect "a prompt naming --v3 still gets it" \
        '--v3|chat|explain --v3' "$V" chat 'explain --v3'

      # ── acp names its engine unless the caller passed an --agent-engine ─────
      # 3.0.0 `acp` takes the engine from `--agent-engine`, then a setting, then
      # a default that is v2 for a listed client or a conflicting option; the
      # global `--v3` is not an input (kiro-kas-dispatch measures both). The
      # scan reads presence only, so any caller selector, in either spelling,
      # suppresses the append and upstream resolves it.
      expect "chat gets no --agent-engine"  '--v3|chat'                 "$V" chat
      expect "mcp gets no --agent-engine"   '--v3|mcp|list'             "$V" mcp list
      expect "caller's --agent-engine=v3 is not doubled" \
        '--v3|acp|--agent-engine=v3'                                      "$V" acp --agent-engine=v3
      expect "caller's --agent-engine v3 is not doubled" \
        '--v3|acp|--agent-engine|v3'                                      "$V" acp --agent-engine v3
      expect "caller's --agent-engine=v2 is left alone" \
        '--v3|acp|--agent-engine=v2'                                      "$V" acp --agent-engine=v2
      expect "caller's --agent-engine before acp is left alone" \
        '--v3|--agent-engine|v2|acp'                                      "$V" --agent-engine v2 acp
      # A conflicting option still reaches upstream, which refuses it under v3.
      expect "acp --model keeps its engine and its option" \
        '--v3|acp|--model|x|--agent-engine=v3'                            "$V" acp --model x
      # A selector past `--` is a positional, so the scan stops there and the
      # engine goes in front of the marker, where `acp` parses it as an option.
      expect "-- ends the engine scan and the engine goes before it" \
        '--v3|acp|--agent-engine=v3|--|--agent-engine=v3'                 "$V" acp -- --agent-engine=v3
      expect "acp -- gets its engine before the marker" \
        '--v3|acp|--agent-engine=v3|--'                                   "$V" acp --
      expect "acp option then -- gets its engine before the marker" \
        '--v3|acp|--model|x|--agent-engine=v3|--|y'                       "$V" acp --model x -- y

      # ── an option VALUE is never read as the subcommand ─────────────────────
      # Reading `acp` as the subcommand in `--agent acp` would append
      # `--agent-engine=v3` to a bare launch, which its parser rejects.
      expect "--agent VALUE is a bare launch"     '--v3|--agent|acp'      "$V" --agent acp
      expect "--agent=VALUE is a bare launch"     '--v3|--agent=acp'      "$V" --agent=acp
      expect "--resume-id VALUE is a bare launch" '--v3|--resume-id|acp'  "$V" --resume-id acp
      expect "--repo VALUE is a bare launch"      '--v3|--repo|acp'       "$V" --repo acp
      # The skipped options are the ones the 3.0.0 top level parses a value for
      # (--agent, --resume-id, --repo). `--model` is a `chat` option: at the top
      # level it is rejected, so the scan does not skip its neighbor and `acp`
      # after it is the subcommand.
      expect "--model VALUE is not skipped"       '--v3|--model|acp|--agent-engine=v3' "$V" --model acp
      expect "--agent VALUE then acp gets its engine" \
        '--v3|--agent|a|acp|--agent-engine=v3'                            "$V" --agent a acp
      expect "a bare launch prompt gets nothing more" \
        '--v3|offline prompt'                                             "$V" 'offline prompt'

      # ── no trust flag reaches any argv ──────────────────────────────────────
      # Under v3 tool trust is permissions.yaml alone (kiro-kas-dispatch); the
      # bare-launch parser rejects `--trust-tools` and `acp --agent-engine=v3`
      # conflicts with it, so a reintroduced injection breaks those launches.
      if grep -qF -- '--trust-tools' "$(readlink -f "$V")"; then
        bad "launcher script carries --trust-tools"
      else
        ok "launcher script carries no --trust-tools"
      fi

      # ── env and extraPackages ride the same launcher ────────────────────────
      expect "env launcher keeps the selectors" '--v3|acp|--agent-engine=v3' "$E" acp
      if [ "$("$E" | sed -n 's/^ENV=//p')" = baked ]; then
        ok "env baked into kiro-cli"
      else
        bad "env not exported by $E"
      fi
      output="$(PATH=${ambientSentinel}/bin "$P")"
      extra="$(printf '%s\n' "$output" | sed -n 's/^EXTRA=//p')"
      ambient="$(printf '%s\n' "$output" | sed -n 's/^AMBIENT=//p')"
      if [ "$extra" = ${lib.getExe extraSentinel} ]; then
        ok "extra package visible from kiro-cli"
      else
        bad "extra package missing from $P: got [$extra]"
      fi
      if [ "$ambient" = ${lib.getExe ambientSentinel} ]; then
        ok "ambient PATH preserved by kiro-cli"
      else
        bad "ambient PATH lost by $P: got [$ambient]"
      fi

      # ── the exec line's shape is depended on outside this repo's Nix ─────────
      # Probe scripts recover the real binary by reading it back out of the
      # wrapper, so keep `exec -a "$0" <realBin> "$@"` intact.
      if grep -qF 'exec -a "$0" ' "$(readlink -f "$V")"; then
        ok "wrapper keeps the exec -a \"\$0\" shape"
      else
        bad "wrapper no longer execs via 'exec -a \"\$0\" <realBin>'"
      fi

      echo "kiro-wrapper-argv: $pass passed, $fail failed"
      [ "$fail" -eq 0 ] || exit 1
      touch "$out"
    '';
}

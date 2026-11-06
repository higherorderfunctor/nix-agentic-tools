# cspell:ignore vwalways walways
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
    # All four launch options set.
    optionsWrapped = wrap {
      launchOptions = {
        acp.authMethod = "client";
        chat = {
          mode = "spec";
          requireMcpStartup = true;
          wrap = "never";
        };
      };
    };
    # Only an acp option, and a chat option that adds nothing (false): neither
    # may change what a chat or bare launch becomes.
    acpOnlyWrapped = wrap {launchOptions.acp.authMethod = "cli";};
    chatFalseWrapped = wrap {launchOptions.chat.requireMcpStartup = false;};
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
      O=${optionsWrapped}/bin/kiro-cli
      A=${acpOnlyWrapped}/bin/kiro-cli
      F=${chatFalseWrapped}/bin/kiro-cli

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

      # ── configured chat and acp options ─────────────────────────────────────
      # `chat` takes its options after the subcommand (and after INPUT), `acp`
      # takes its own after the engine selector; each is one `--name=value` word
      # and goes before an end-of-options `--`. A wrapper that put a chat option
      # in front of `chat`, or an acp option on `chat`, fails these.
      expect "chat gets every configured option" \
        '--v3|chat|--mode=spec|--require-mcp-startup|--wrap=never'        "$O" chat
      expect "chat INPUT stays before the options" \
        '--v3|chat|hello|--mode=spec|--require-mcp-startup|--wrap=never'  "$O" chat hello
      expect "acp gets its engine and its option, no chat option" \
        '--v3|acp|--agent-engine=v3|--auth-method=client'                 "$O" acp
      expect "mcp gets neither tier" \
        '--v3|mcp|list'                                                   "$O" mcp list
      # The caller's own option wins, in each spelling; a repeat would abort with
      # "cannot be used multiple times" (measured on 3.0.0).
      expect "caller's --wrap=never is not doubled" \
        '--v3|chat|--wrap=never|--mode=spec|--require-mcp-startup'        "$O" chat --wrap=never
      expect "caller's --wrap always wins over the configured never" \
        '--v3|chat|--wrap|always|--mode=spec|--require-mcp-startup'       "$O" chat --wrap always
      expect "caller's -w is the --wrap option" \
        '--v3|chat|-w|always|--mode=spec|--require-mcp-startup'           "$O" chat -w always
      expect "caller's attached -walways is the --wrap option" \
        '--v3|chat|-walways|--mode=spec|--require-mcp-startup'            "$O" chat -walways
      # A short option inside a cluster is the option (clap reads `-vw always` as
      # `-v -w always`, and `-wv` as `-w` with the value `v`), so injecting beside
      # it repeats the option and aborts (measured). A scan that matched whole
      # tokens only fails these; so does one that read on after a value.
      expect "caller's clustered -vw is the --wrap option" \
        '--v3|chat|-vw|always|--mode=spec|--require-mcp-startup'          "$O" chat -vw always
      expect "caller's clustered -vwalways is the --wrap option" \
        '--v3|chat|-vwalways|--mode=spec|--require-mcp-startup'           "$O" chat -vwalways
      expect "-wv is --wrap with the value v" \
        '--v3|chat|-wv|--mode=spec|--require-mcp-startup'                 "$O" chat -wv
      # `-d` takes a value, so the `w` after it is its value: no --wrap passed.
      expect "-dw is --delete-session with the value w" \
        '--v3|chat|-dw|--mode=spec|--require-mcp-startup|--wrap=never'    "$O" chat -dw
      expect "-v alone is not --wrap" \
        '--v3|chat|-v|--mode=spec|--require-mcp-startup|--wrap=never'     "$O" chat -v
      expect "caller's --require-mcp-startup is not doubled" \
        '--v3|chat|--require-mcp-startup|--mode=spec|--wrap=never'        "$O" chat --require-mcp-startup
      expect "caller's acp --authMethod alias is the --auth-method option" \
        '--v3|acp|--authMethod=cli|--agent-engine=v3'                     "$O" acp --authMethod=cli
      expect "caller's acp --auth-method value is not doubled" \
        '--v3|acp|--auth-method|cli|--agent-engine=v3'                    "$O" acp --auth-method cli
      expect "caller's acp --authMethod value is not doubled" \
        '--v3|acp|--authMethod|cli|--agent-engine=v3'                     "$O" acp --authMethod cli
      # A caller's chat --mode wins in both spellings, even though `mode = spec`
      # is configured: no second --mode is added.
      expect "caller's --mode value wins over the configured spec" \
        '--v3|chat|--mode|default|--require-mcp-startup|--wrap=never'     "$O" chat --mode default
      expect "caller's --mode=default wins over the configured spec" \
        '--v3|chat|--mode=default|--require-mcp-startup|--wrap=never'     "$O" chat --mode=default
      # A token past `--` is a positional: it neither suppresses nor receives.
      expect "chat options go before --, and a --wrap past it does not count" \
        '--v3|chat|--mode=spec|--require-mcp-startup|--wrap=never|--|--wrap=always' "$O" chat -- --wrap=always
      expect "chat INPUT then -- keeps the options before the marker" \
        '--v3|chat|hello|--mode=spec|--require-mcp-startup|--wrap=never|--|--x' "$O" chat hello -- --x
      expect "acp -- keeps the options before the marker" \
        '--v3|acp|--agent-engine=v3|--auth-method=client|--|x'            "$O" acp -- x

      # ── a bare launch becomes `chat` only when a chat option is configured ──
      # Without that, a wrapper that always rewrote would change the argv of a
      # consumer who set none.
      expect "bare launch becomes chat with its options" \
        '--v3|chat|--mode=spec|--require-mcp-startup|--wrap=never'        "$O"
      expect "bare launch keeps its top-level option before chat" \
        '--v3|--agent|a|chat|--mode=spec|--require-mcp-startup|--wrap=never' "$O" --agent a
      expect "no chat option: a bare launch stays bare"        '--v3'     "$V"
      expect "an acp-only option leaves a bare launch bare"    '--v3'     "$A"
      expect "an acp-only option adds nothing to chat"         '--v3|chat' "$A" chat
      expect "an acp-only option reaches acp" \
        '--v3|acp|--agent-engine=v3|--auth-method=cli'                    "$A" acp
      expect "a false chat option leaves a bare launch bare"   '--v3'     "$F"
      expect "a false chat option adds nothing to chat"        '--v3|chat' "$F" chat
      # The once-per-invocation top-level options and every non-chat subcommand
      # are untouched: `chat` rejects `-V` and `--help-all` (measured), and an
      # inserted `chat` would turn `login` or `--resume-id x` into something else.
      expect "--version is not rewritten"      '--v3|--version'           "$O" --version
      expect "-V is not rewritten"             '--v3|-V'                  "$O" -V
      expect "--help is not rewritten"         '--v3|--help'              "$O" --help
      expect "-h is not rewritten"             '--v3|-h'                  "$O" -h
      # Clustered one-offs: `-rv` is `-r -v`, both once-per-invocation, so the
      # launch is not rewritten. A scan that matched whole tokens only turns
      # `-rv` into `chat -rv`.
      expect "-v alone is not rewritten"       '--v3|-v'                  "$O" -v
      expect "-rv is not rewritten"            '--v3|-rv'                 "$O" -rv
      expect "-vr is not rewritten"            '--v3|-vr'                 "$O" -vr
      expect "--help-all is not rewritten"     '--v3|--help-all'          "$O" --help-all
      expect "--resume-id VALUE is not rewritten" \
        '--v3|--resume-id|x'                                              "$O" --resume-id x
      expect "settings is not rewritten"       '--v3|settings|all'        "$O" settings all
      expect "login is not rewritten"          '--v3|login'               "$O" login
      expect "a bare launch prompt is not rewritten" \
        '--v3|offline prompt'                                             "$O" 'offline prompt'
      # One-off options with no chat meaning, and the `--list` alias of
      # `--resume-picker`, leave a bare launch untouched.
      expect "--resume-picker is not rewritten" '--v3|--resume-picker'    "$O" --resume-picker
      expect "--list is not rewritten"         '--v3|--list'              "$O" --list
      # An empty-string argument is a positional (a subcommand of no name), not
      # the absence of one, so `chat` is inserted for neither.
      expect "an empty argument is not rewritten" \
        '--v3|'                                                           "$O" ""
      expect "an empty argument before settings is not rewritten" \
        '--v3||settings'                                                  "$O" "" settings
      expect "-- is not rewritten"             '--v3|--'                  "$O" --
      expect "-- then options is not rewritten" '--v3|--|--wrap'          "$O" -- --wrap
      # `chat` appended after a value option that has no value would be read as
      # that value: `--agent chat` names an agent.
      expect "a dangling --agent is not rewritten" '--v3|--agent'         "$O" --agent

      # ── no trust flag reaches any argv ──────────────────────────────────────
      # Under v3 tool trust is permissions.yaml alone (kiro-kas-dispatch); the
      # bare-launch parser rejects `--trust-tools` and `acp --agent-engine=v3`
      # conflicts with it, so a reintroduced injection breaks those launches.
      if grep -qF -- '--trust-tools' "$(readlink -f "$V")"; then
        bad "launcher script carries --trust-tools"
      else
        ok "launcher script carries no --trust-tools"
      fi
      # Nor any other trust flag, nor a Kiro home, once every option is set.
      for forbidden in --trust KIRO_HOME KIRO_DATA_DIR; do
        if grep -qF -- "$forbidden" "$(readlink -f "$O")"; then
          bad "configured launcher script carries $forbidden"
        else
          ok "configured launcher script carries no $forbidden"
        fi
      done

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

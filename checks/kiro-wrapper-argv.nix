# Behavioral test for packages/kiro-cli/lib/wrapPackage.nix — the argv the
# kiro-cli wrappers actually forward.
#
# The launcher flags are CLI-GLOBAL, so their argv POSITION is the whole
# correctness question: appended after a subcommand they are parsed against that
# subcommand's parser and clap rejects them ("unexpected argument '--tui'"),
# while prepended they are accepted everywhere. That failure is invisible from
# the Nix side — the generated script is well-formed either way — so this drives
# the REAL wrapper against a stub package that prints its argv.
#
# String-matching the generated bash (checks/module-eval.nix) cannot catch a
# flag emitted on the wrong side of the subcommand, nor a scan that mis-parses
# `--agent acp` as the `acp` subcommand. Running it can.
{
  lib,
  pkgs,
  ...
}: let
  wrapKiroPackage = import ../packages/kiro-cli/lib/wrapPackage.nix {inherit lib pkgs;};

  # Stand-in for the real kiro-cli: prints the argv it received (one ARG line
  # per token, so an empty or space-bearing argument stays unambiguous) plus one
  # baked env var, which is how the env-export path is asserted.
  # `${KIRO_WRAPPER_TEST-unset}` keeps its default so the `-u` in strict mode
  # reports an unbaked env var rather than aborting the stub.
  echoArgv = pkgs.writeShellScript "kiro-cli-stub-argv" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf 'ENV=%s\n' "''${KIRO_WRAPPER_TEST-unset}"
    for nat_a in "$@"; do printf 'ARG=%s\n' "$nat_a"; done
  '';
  stubPackage = pkgs.runCommandLocal "kiro-cli-stub" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${echoArgv} "$out/bin/kiro-cli"
    ln -s ${echoArgv} "$out/bin/kiro-cli-chat"
  '';

  # A launcher stub that DISPATCHES, so the two wrappers compose the way they do
  # in a real profile. The real `kiro-cli` resolves `kiro-cli-chat` through PATH
  # — verified by removing the wrapped bin dir from PATH, which makes it fail
  # with "No such file or directory" rather than falling back to its own store
  # dir. So `kiro-cli acp` runs the launcher wrapper AND the chat wrapper, and
  # their injections land in ONE argv.
  #
  # Testing each binary alone cannot see that: it is what let a `--v3` prepend
  # and a `--trust-tools` append meet on `acp` and abort the command.
  #
  # The launcher does NOT relay argv — it injects, translates and drops. Every
  # row below was measured by putting a printing `kiro-cli-chat` first on PATH
  # and reading the argv it received from the real 2.15.2 launcher:
  #
  #   kiro-cli                      ->  chat
  #   kiro-cli --                   ->  chat
  #   kiro-cli --agent acp          ->  chat --agent acp
  #   kiro-cli --tui                ->  chat --tui
  #   kiro-cli --tui --v3           ->  chat --tui --v3
  #   kiro-cli --v3                 ->  chat --v3
  #   kiro-cli --tui chat           ->  chat
  #   kiro-cli --tui --v3 chat      ->  chat --v3
  #   kiro-cli acp                  ->  acp
  #   kiro-cli --tui acp            ->  acp
  #   kiro-cli --v3 acp             ->  acp --agent-engine v3
  #   kiro-cli --tui --v3 acp       ->  acp --agent-engine v3
  #   kiro-cli --v3 acp --agent-engine=v2  ->  acp --agent-engine=v2
  #   kiro-cli --v3 mcp list        ->  mcp list
  #   kiro-cli settings all         ->  settings list
  #   kiro-cli whoami               ->  (kept in-process, never dispatched)
  #
  # Four rules fall out, and the stub implements all four:
  #
  #  1. ALWAYS dispatch, injecting `chat` when no subcommand is present. A
  #     value-taking option's VALUE is not a subcommand, exactly as in
  #     `subcommandBlock` — `--agent acp` is a bare launch.
  #  2. `--tui` survives ONLY on a bare launch. Give the invocation an explicit
  #     subcommand — `chat` included — and the launcher drops it. So injecting
  #     `--tui` on an explicit `chat` is a no-op upstream, and its inertness on
  #     `acp` is structural rather than an observed no-op.
  #  3. `--v3` is TRANSLATED to `--agent-engine v3` for `acp`, forwarded
  #     verbatim for `chat`/bare, and DROPPED for everything else.
  #  4. A caller's own `--agent-engine` suppresses the translation.
  #
  # Rule 3 is why the chat wrapper's engine fallback must be the chat binary's
  # own default rather than this config's: on the real chain the engine arrives
  # as an EXPLICIT token, so the wrapper never needs to guess, and a stub that
  # skipped the translation would have let a wrong guess look correct.
  #
  # `settings all -> settings list` and the in-process `whoami` are the two
  # rows left unimplemented; no assertion turns on either.
  dispatchLauncher = pkgs.writeShellScript "kiro-cli-stub-launcher" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    # Pass 1 — classify, skipping the value of a value-taking global.
    nat_sub=""
    nat_skip=0
    nat_v3=0
    nat_engine=0
    for nat_a in "$@"; do
      if [ "$nat_skip" = 1 ]; then nat_skip=0; continue; fi
      case "$nat_a" in
        --v3) nat_v3=1 ;;
        --agent-engine|--agent-engine=*) nat_engine=1 ;;
        --agent|--resume-id) nat_skip=1 ;;
        --) ;;
        -*) ;;
        *) if [ -z "$nat_sub" ]; then nat_sub="$nat_a"; fi ;;
      esac
    done

    # Pass 2 — rebuild "$@" by rotating: shift each original off the front and
    # push the survivors onto the back, so relative order is preserved. The
    # subcommand token is pulled OUT here and re-emitted at the front below,
    # because the launcher leads with it: `--v3 chat` arrives as `chat --v3`.
    nat_n=$#
    nat_i=0
    nat_took_sub=0
    while [ "$nat_i" -lt "$nat_n" ]; do
      nat_a="$1"
      shift
      case "$nat_a" in
        --) ;;
        --tui)
          if [ -z "$nat_sub" ]; then set -- "$@" --tui; fi
          ;;
        --v3)
          if [ -z "$nat_sub" ] || [ "$nat_sub" = chat ]; then set -- "$@" --v3; fi
          ;;
        *)
          if [ "$nat_took_sub" = 0 ] && [ -n "$nat_sub" ] && [ "$nat_a" = "$nat_sub" ]; then
            nat_took_sub=1
          else
            set -- "$@" "$nat_a"
          fi
          ;;
      esac
      nat_i=$((nat_i + 1))
    done

    if [ "$nat_sub" = acp ] && [ "$nat_v3" = 1 ] && [ "$nat_engine" = 0 ]; then
      set -- "$@" --agent-engine v3
    fi
    if [ -n "$nat_sub" ]; then set -- "$nat_sub" "$@"; else set -- chat "$@"; fi
    exec kiro-cli-chat "$@"
  '';
  chainPackage = pkgs.runCommandLocal "kiro-cli-chain-stub" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${dispatchLauncher} "$out/bin/kiro-cli"
    ln -s ${echoArgv} "$out/bin/kiro-cli-chat"
  '';

  wrap = args:
    wrapKiroPackage ({
        package = stubPackage;
        tui = false;
        v3 = false;
        trustedMcpTools = [];
      }
      // args);
  wrapChain = args:
    wrapKiroPackage ({
        package = chainPackage;
        tui = false;
        v3 = false;
        trustedMcpTools = [];
      }
      // args);

  # The consumer shape that broke: v3 active AND trustedMcpTools non-empty.
  chainTrustV3 = wrapChain {
    tui = true;
    trustedMcpTools = ["fs_read"];
  };
  # Same, without v3 — `--trust-tools` must still reach acp there.
  chainTrustV2 = wrapChain {trustedMcpTools = ["fs_read"];};

  # tui ⇒ --tui (bare/chat only) + --v3 (everywhere) on the launcher.
  tuiWrapped = wrap {tui = true;};
  # v3 alone ⇒ --v3 everywhere, never --tui.
  v3Wrapped = wrap {v3 = true;};
  # trustedMcpTools ⇒ --trust-tools=… appended on the chat binary.
  trustWrapped = wrap {trustedMcpTools = ["fs_read" "@srv"];};
  # env only: the wrapper exists to export, and must inject nothing at all.
  envWrapped = wrap {environmentVariables.KIRO_WRAPPER_TEST = "baked";};
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

    L=${tuiWrapped}/bin/kiro-cli
    V=${v3Wrapped}/bin/kiro-cli
    T=${trustWrapped}/bin/kiro-cli-chat
    E=${envWrapped}/bin/kiro-cli
    EC=${envWrapped}/bin/kiro-cli-chat

    # ── the globals land BEFORE the subcommand, never after ─────────────────
    # This is the regression that mattered: `kiro-cli acp --tui --v3` is
    # "error: unexpected argument '--tui' found", while `--tui --v3 acp` runs.
    expect "bare launch"                  '--tui|--v3'                "$L"
    expect "chat keeps both, in front"    '--tui|--v3|chat'           "$L" chat
    expect "chat INPUT stays last"        '--tui|--v3|chat|hello'     "$L" chat hello
    expect "acp gets --v3, before it"     '--v3|acp'                  "$L" acp
    expect "mcp gets --v3, before it"     '--v3|mcp|list'             "$L" mcp list
    expect "agent gets --v3, before it"   '--v3|agent|list'           "$L" agent list
    expect "settings gets --v3"           '--v3|settings|all'         "$L" settings all
    expect "whoami gets --v3"             '--v3|whoami'               "$L" whoami

    # ── --tui is confined to bare + chat; --v3 is not ───────────────────────
    # --tui means "launch chat in TUI mode"; it is meaningless for a stdio
    # protocol (acp) or for mcp/settings, so it is withheld there.
    for sub in acp mcp agent settings whoami translate; do
      if [ -z "$(argv "$L" "$sub" | tr '|' '\n' | grep -Fx -- --tui || true)" ]; then
        ok "--tui withheld from $sub"
      else
        bad "--tui leaked into $sub"
      fi
    done

    # ── v3 without tui never emits --tui, anywhere ──────────────────────────
    expect "v3-only bare"                 '--v3'                      "$V"
    expect "v3-only chat"                 '--v3|chat'                 "$V" chat
    expect "v3-only acp"                  '--v3|acp'                  "$V" acp

    # ── an option VALUE is never read as the subcommand ─────────────────────
    # Without the value skip, `--agent acp` looks like the acp subcommand and
    # the bare launch silently loses --tui.
    expect "--agent VALUE is a bare launch"    '--tui|--v3|--agent|acp'   "$L" --agent acp
    expect "--agent=VALUE is a bare launch"    '--tui|--v3|--agent=acp'   "$L" --agent=acp
    expect "value skip finds a later chat"     '--tui|--v3|--agent|a|chat' "$L" --agent a chat
    expect "--resume-id VALUE is a bare launch" '--tui|--v3|--resume-id|s1' "$L" --resume-id s1
    expect "-r is a bare launch"               '--tui|--v3|-r'            "$L" -r

    # ── idempotence: a caller's own flag is never doubled ───────────────────
    # Both --tui and --v3 abort with "cannot be used multiple times".
    expect "caller's --tui not doubled"   '--v3|chat|--tui'           "$L" chat --tui
    # acp: --v3 already present so nothing is prepended, and --tui stays
    # withheld by the gate — so the argv passes through untouched.
    expect "caller's --v3 not doubled"    'acp|--v3'                  "$L" acp --v3
    expect "caller passing both"          'chat|--tui|--v3'           "$L" chat --tui --v3
    # Exact-token match, not a substring scan of "$*": a prompt that merely
    # mentions the flag must not suppress the real one.
    expect "a prompt naming --tui still gets it" \
      '--tui|--v3|chat|explain --tui' "$L" chat 'explain --tui'

    # ── `--` parks the scan; --tui is withheld, --v3 is global so still leads ─
    expect "-- withholds --tui"           '--v3|--'                   "$L" --

    # ── chat binary: --trust-tools is APPENDED, chat/acp only ───────────────
    # Opposite case to the globals: the chat binary declares --trust-tools on
    # those two subcommands and NOT at top level.
    expect "chat gets --trust-tools"      'chat|--trust-tools=fs_read,@srv'  "$T" chat
    expect "acp gets --trust-tools"       'acp|--trust-tools=fs_read,@srv'   "$T" acp
    expect "bare chat binary gets none"   ""                                 "$T"
    expect "mcp gets no --trust-tools"    'mcp|list'                         "$T" mcp list
    expect "whoami gets no --trust-tools" 'whoami'                           "$T" whoami

    # ── env-only wrapper injects nothing but still exports ──────────────────
    expect "env-only launcher transparent"  'acp'                     "$E" acp
    expect "env-only launcher bare"         ""                        "$E"
    expect "env-only chat transparent"      'mcp|list'                "$EC" mcp list
    for bin in "$E" "$EC"; do
      if [ "$("$bin" | sed -n 's/^ENV=//p')" = baked ]; then
        ok "env baked into $(basename "$bin")"
      else
        bad "env not exported by $bin"
      fi
    done

    # ── the two wrappers COMPOSED, as they do in a real profile ─────────────
    # The launcher finds kiro-cli-chat on PATH, so both wrappers run and their
    # injections meet in one argv. Under v3 that pairing is fatal on `acp`:
    # upstream declares --agent-engine=v3 mutually exclusive with --trust-tools,
    # so `kiro-cli acp` died with "not supported with --agent-engine=v3".
    # Under home-manager little is lost by withholding it — trustedMcpTools is
    # also expressed in settings/permissions.yaml — though that translation is
    # HM-only, so the devenv backend does not recover the grant declaratively.
    chain() {
      local wrapped="$1"
      shift
      PATH="$wrapped/bin:$PATH" "$wrapped/bin/kiro-cli" "$@" \
        | sed -n 's/^ARG=//p' | paste -sd'|' -
    }
    chain_expect() {
      local label="$1" want="$2" got
      shift 2
      got="$(chain "$@")"
      if [ "$got" = "$want" ]; then
        ok "$label"
      else
        bad "$label: want [$want] got [$got]"
      fi
    }

    # The withhold fires through the TRANSLATED token: the launcher hands the
    # chat wrapper `acp --agent-engine v3`, not the `--v3` the caller typed.
    chain_expect "v3+trust: acp gets NO --trust-tools" \
      'acp|--agent-engine|v3' ${chainTrustV3} acp
    # An EXPLICIT subcommand makes the launcher drop `--tui`, so the wrapper's
    # injection of it on `chat` is a no-op upstream (it survives only bare).
    chain_expect "v3+trust: chat still gets --trust-tools" \
      'chat|--v3|--trust-tools=fs_read' ${chainTrustV3} chat
    chain_expect "no v3: acp still gets --trust-tools" \
      'acp|--trust-tools=fs_read' ${chainTrustV2} acp
    chain_expect "no v3: chat still gets --trust-tools" \
      'chat|--trust-tools=fs_read' ${chainTrustV2} chat

    # ── the launcher's own scan: a VALUE is not a subcommand ────────────────
    # The real launcher forwards `kiro-cli --agent acp` as `chat --agent acp` —
    # a bare launch. If the stub dispatched on `acp` instead, the chat wrapper
    # would read it as the acp subcommand, the v3 gate would fire, and
    # --trust-tools would be withheld from what is really a chat launch.
    chain_expect "value skip: --agent VALUE is a bare launch" \
      'chat|--tui|--v3|--agent|acp|--trust-tools=fs_read' \
      ${chainTrustV3} --agent acp
    # A bare launch is dispatched too, with `chat` injected as the subcommand,
    # so the chat-side gate fires on it — and it is the ONE shape where `--tui`
    # survives the launcher.
    chain_expect "bare launch dispatches as chat, keeping --tui" \
      'chat|--tui|--v3|--trust-tools=fs_read' \
      ${chainTrustV3}

    # ── the EFFECTIVE engine decides, and only argv knows it ────────────────
    # A caller's --agent-engine overrides the injected --v3 — upstream drops the
    # injected flag outright, measured: `kiro-cli --v3 acp --agent-engine=v2`
    # forwards `acp --agent-engine=v2`. Both directions are real against the
    # binary: `--v3 acp --agent-engine=v2 --trust-tools=x` RUNS, while
    # `acp --agent-engine=v3 --trust-tools=x` CONFLICTS.
    chain_expect "v3 config, caller opts out -> trust returns" \
      'acp|--agent-engine=v2|--trust-tools=fs_read' \
      ${chainTrustV3} acp --agent-engine=v2
    chain_expect "v3 config, caller opts out (two-token form)" \
      'acp|--agent-engine|v2|--trust-tools=fs_read' \
      ${chainTrustV3} acp --agent-engine v2
    chain_expect "v3 config, caller re-asks for v3 -> still withheld" \
      'acp|--agent-engine=v3' \
      ${chainTrustV3} acp --agent-engine=v3
    chain_expect "no-v3 config, caller opts IN -> withheld" \
      'acp|--agent-engine=v3' \
      ${chainTrustV2} acp --agent-engine=v3
    chain_expect "no-v3 config, caller picks v1 -> trust kept" \
      'acp|--agent-engine=v1|--trust-tools=fs_read' \
      ${chainTrustV2} acp --agent-engine=v1
    # chat is unconditional: v3 + chat + --trust-tools parses fine.
    chain_expect "chat is unaffected by the engine" \
      'chat|--v3|--agent-engine=v3|--trust-tools=fs_read' \
      ${chainTrustV3} chat --agent-engine=v3

    # ── the chat binary reached DIRECTLY, with the launcher out of the chain ─
    # This is what forces the fallback to be the chat binary's own default and
    # not the Nix config's. `kiro-cli-chat acp` runs the v2 engine no matter
    # what `v3 = true` says — there is no launcher to translate anything — so
    # withholding --trust-tools here would strip a grant the session accepts.
    expect "direct chat binary under a v3 config keeps --trust-tools" \
      'acp|--trust-tools=fs_read' \
      ${chainTrustV3}/bin/kiro-cli-chat acp

    # A `--` ends the engine scan. Past it a flag-looking token is a positional
    # the CLI will not honour, so neither do we. Measured on the direct
    # kiro-cli-chat path: `acp -- --agent-engine=v3` is "unexpected argument",
    # i.e. NOT an engine selection. (Through the launcher the point is moot —
    # it strips `--` before forwarding — so this only ever relaxes, never
    # tightens, what the launcher path sees.)
    expect "-- ends the engine scan" \
      'acp|--|--agent-engine=v3|--trust-tools=fs_read,@srv' \
      ${trustWrapped}/bin/kiro-cli-chat acp -- --agent-engine=v3

    # ── the exec line's shape is depended on outside this repo's Nix ─────────
    # Probe scripts recover the real binary by reading it back out of the
    # wrapper, so keep `exec -a "$0" <realBin> "$@"` intact.
    if grep -qF 'exec -a "$0" ' "$(readlink -f "$L")"; then
      ok "wrapper keeps the exec -a \"\$0\" shape"
    else
      bad "wrapper no longer execs via 'exec -a \"\$0\" <realBin>'"
    fi

    echo "kiro-wrapper-argv: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    touch "$out"
  ''

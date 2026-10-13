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
# String-matching the generated bash (packages/kiro-cli/checks/module-eval.nix) cannot catch a
# flag emitted on the wrong side of the subcommand, nor a scan that mis-parses
# `--agent acp` as the `acp` subcommand. Running it can.
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
      ln -s ${echoArgv} "$out/bin/kiro-cli-chat"
    '';

    # A launcher stub that DISPATCHES, preserving the measured pre-split
    # forwarding contract and exercising how the two wrappers interact when PATH
    # dispatch traverses both. Current Linux buildFHSEnv startup instead finds its
    # raw /usr/bin/kiro-cli-chat before the inherited outer wrapper, so this stub
    # is not a model of that FHS resolution boundary.
    #
    # Testing each binary alone cannot see that: it is what let a `--v3` prepend
    # and a `--trust-tools` append meet on `acp` and abort the command.
    #
    # The launcher does NOT relay argv — it injects, translates and drops. Every
    # row below was measured pre-split by putting a printing `kiro-cli-chat` first
    # on PATH and reading the argv it received from the real 2.15.2 launcher:
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
          trustedMcpTools = [];
        }
        // args);
    wrapChain = args:
      wrapKiroPackage ({
          package = chainPackage;
          trustedMcpTools = [];
        }
        // args);

    # The consumer shape that broke: v3 active AND trustedMcpTools non-empty.
    chainTrustV3 = wrapChain {
      defaultEngine = "v3";
      trustedMcpTools = ["fs_read"];
    };
    # Same, without v3 — `--trust-tools` must still reach acp there.
    chainTrustV2 = wrapChain {trustedMcpTools = ["fs_read"];};

    # An environment-only wrapper must leave engine and UI selection native.
    v3Wrapped = wrap {environmentVariables.KIRO_WRAPPER_TEST = "baked";};
    # trustedMcpTools ⇒ --trust-tools=… appended on the chat binary.
    trustWrapped = wrap {trustedMcpTools = ["fs_read" "@srv"];};
    # env only: the wrapper exists to export, and must inject nothing at all.
    envWrapped = wrap {environmentVariables.KIRO_WRAPPER_TEST = "baked";};
    # extraPackages only: the wrapper prepends its bins without discarding the
    # caller's PATH, and must inject no argv.
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

      V=${v3Wrapped}/bin/kiro-cli
      T=${trustWrapped}/bin/kiro-cli-chat
      E=${envWrapped}/bin/kiro-cli
      EC=${envWrapped}/bin/kiro-cli-chat
      P=${pathWrapped}/bin/kiro-cli
      PC=${pathWrapped}/bin/kiro-cli-chat

      # Engine selection is absent from the module wrapper. Native terminal
      # settings and the package's ACP default are tested against real binaries.
      expect "bare launcher receives no engine flag" "" "$V"
      expect "terminal arguments stay unchanged" 'chat|hello' "$V" chat hello
      expect "ACP default belongs to package" 'acp' "$V" acp
      expect "explicit engine remains unchanged" 'chat|--v3' "$V" chat --v3
      expect "UI policy stays native" 'chat|--tui' "$V" chat --tui

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

      # ── extraPackages prepends store bins and preserves ambient PATH ─────────
      for bin in "$P" "$PC"; do
        output="$(PATH=${ambientSentinel}/bin "$bin")"
        extra="$(printf '%s\n' "$output" | sed -n 's/^EXTRA=//p')"
        ambient="$(printf '%s\n' "$output" | sed -n 's/^AMBIENT=//p')"
        if [ "$extra" = ${lib.getExe extraSentinel} ]; then
          ok "extra package visible from $(basename "$bin")"
        else
          bad "extra package missing from $bin: got [$extra]"
        fi
        if [ "$ambient" = ${lib.getExe ambientSentinel} ]; then
          ok "ambient PATH preserved by $(basename "$bin")"
        else
          bad "ambient PATH lost by $bin: got [$ambient]"
        fi
      done
      expect "extraPackages-only launcher transparent" 'acp' "$P" acp
      expect "extraPackages-only chat transparent" 'mcp|list' "$PC" mcp list

      # ── the two wrappers composed at the wrapper layer ──────────────────────
      # This pins their argv contract when PATH dispatch traverses both wrappers.
      # Current Linux buildFHSEnv startup puts its raw /usr/bin/kiro-cli-chat
      # ahead of the inherited outer wrapper, so this is deliberately not an FHS
      # integration assertion. When both do run, their injections meet in one
      # argv. Under v3 that pairing is fatal on `acp`:
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

      # No explicit engine: the declared build default controls trust withholding.
      chain_expect "v3+trust: acp gets NO --trust-tools" \
        'acp' ${chainTrustV3} acp
      # An EXPLICIT subcommand makes the launcher drop `--tui`, so the wrapper's
      # injection of it on `chat` is a no-op upstream (it survives only bare).
      chain_expect "v3+trust: chat still gets --trust-tools" \
        'chat|--trust-tools=fs_read' ${chainTrustV3} chat
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
        'chat|--agent|acp|--trust-tools=fs_read' \
        ${chainTrustV3} --agent acp
      # A bare launch is dispatched too, with `chat` injected as the subcommand,
      # so the chat-side gate fires on it.
      chain_expect "bare launch dispatches as chat" \
        'chat|--trust-tools=fs_read' \
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
        'chat|--agent-engine=v3|--trust-tools=fs_read' \
        ${chainTrustV3} chat --agent-engine=v3

      # Direct chat has the same declared package ACP default; withhold trust
      # before the package wrapper injects it.
      expect "direct ACP honors declared engine for trust" \
        'acp' \
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

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
#
# `acp` is the one subcommand that does not read the global `--v3` on 3.0.0, so
# the v3 wrapper names its engine with an appended `--agent-engine=v3` instead;
# the `acp` rows below pin that selector and every case that must not get it.
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

    wrap = args:
      wrapKiroPackage ({
          package = stubPackage;
          v3 = false;
          trustedMcpTools = [];
        }
        // args);

    # Production's Linux shape, without bubblewrap: an FHS package whose
    # `bin/kiro-cli` reaches the payload's command the way the synthesized
    # root's /usr/bin does, and which exposes the same `unwrapped` /
    # `withFhsPayload` seam as the overlay. The module therefore places the
    # trust wrapper inside the payload and keeps the `--v3` prepend outside,
    # exactly as it does for the real package. Nested user namespaces are not
    # portable in a build sandbox; kiro-fhs-contract pins the real launcher,
    # init and dispatcher literals this stub stands in for.
    fhsStubFor = payload:
      pkgs.runCommandLocal "kiro-cli-fhs-stub" {
        passthru = {
          unwrapped = fhsPayloadStub;
          withFhsPayload = fhsStubFor;
        };
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/bin"
        for nat_command in kiro-cli kiro-cli-chat; do
          {
            printf '#!%s\n' ${lib.escapeShellArg pkgs.runtimeShell}
            printf '%s\n' 'set -euETo pipefail' 'shopt -s inherit_errexit 2>/dev/null || :'
            printf 'exec %s/bin/%s "$@"\n' ${lib.escapeShellArg "${payload}"} "$nat_command"
          } > "$out/bin/$nat_command"
          chmod +x "$out/bin/$nat_command"
        done
      '';
    # The module's inner trust package inherits `meta` and `version` from
    # `unwrapped`, as nixpkgs' FHS expression does from its payload.
    fhsPayloadStub = stubPackage.overrideAttrs (_: {version = "0-stub";});
    fhsStub = fhsStubFor fhsPayloadStub;
    # Linux places trust inside the payload; elsewhere the seam is not used
    # and the outer wrapper carries it. The argv each command receives is the
    # same either way, which is what the `F*` expectations below pin.
    trustInsideFhs = pkgs.stdenv.hostPlatform.isLinux;

    # v3 ⇒ --v3 everywhere. There is no `tui` option any more: it injected
    # `--tui` and implied `--v3`, and `--tui` is redundant under v3.
    v3Wrapped = wrap {v3 = true;};
    # trustedMcpTools ⇒ --trust-tools=… appended on both commands.
    trustWrapped = wrap {trustedMcpTools = ["fs_read" "@srv"];};
    # The default consumer shape: v3 injected AND trustedMcpTools non-empty.
    trustV3Wrapped = wrap {
      v3 = true;
      trustedMcpTools = ["fs_read"];
    };
    # Same, without v3 — the caller's own `--v3` must still withhold on acp.
    trustV2Wrapped = wrap {trustedMcpTools = ["fs_read"];};
    # The FHS composition under the same two configurations.
    fhsTrustV3 = wrapKiroPackage {
      package = fhsStub;
      v3 = true;
      trustedMcpTools = ["fs_read"];
    };
    fhsTrustV2 = wrapKiroPackage {
      package = fhsStub;
      v3 = false;
      trustedMcpTools = ["fs_read"];
    };
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
      LV=${trustV3Wrapped}/bin/kiro-cli
      L2=${trustV2Wrapped}/bin/kiro-cli
      FV=${fhsTrustV3}/bin/kiro-cli
      F2=${fhsTrustV2}/bin/kiro-cli
      E=${envWrapped}/bin/kiro-cli
      EC=${envWrapped}/bin/kiro-cli-chat
      P=${pathWrapped}/bin/kiro-cli
      PC=${pathWrapped}/bin/kiro-cli-chat

      # ── the global lands BEFORE the subcommand, never after ─────────────────
      # This is the regression that mattered: `kiro-cli acp --v3` is "error:
      # unexpected argument found", while `--v3 acp` runs. A string match on the
      # generated bash cannot catch a flag emitted on the wrong SIDE; running it
      # can.
      expect "bare launch"                  '--v3'                      "$V"
      expect "chat keeps it in front"       '--v3|chat'                 "$V" chat
      expect "chat INPUT stays last"        '--v3|chat|hello'           "$V" chat hello
      # `acp` ignores `--v3` on 3.0.0, so it also gets the engine appended.
      expect "acp gets --v3, before it, and its engine" \
        '--v3|acp|--agent-engine=v3'                                      "$V" acp
      expect "mcp gets --v3, before it"     '--v3|mcp|list'             "$V" mcp list
      expect "agent gets --v3, before it"   '--v3|agent|list'           "$V" agent list
      expect "settings gets --v3"           '--v3|settings|all'         "$V" settings all
      expect "whoami gets --v3"             '--v3|whoami'               "$V" whoami

      # ── the removed `tui` option must not resurrect itself ──────────────────
      # `--tui` is redundant under v3 (which already uses the new TUI harness)
      # and it is going away with v3. Nothing this module generates may emit it.
      for sub in "" chat acp mcp agent settings whoami translate; do
        if [ -z "$(argv "$V" $sub | tr '|' '\n' | grep -Fx -- --tui || true)" ]; then
          ok "--tui absent from ''${sub:-bare launch}"
        else
          bad "--tui emitted for ''${sub:-bare launch}"
        fi
      done

      # ── v3 never emits --tui, anywhere ──────────────────────────────────────
      expect "v3-only bare"                 '--v3'                      "$V"
      expect "v3-only chat"                 '--v3|chat'                 "$V" chat
      expect "v3-only acp"                  '--v3|acp|--agent-engine=v3' "$V" acp

      # ── an option VALUE is never read as the subcommand ─────────────────────
      # The LAUNCHER no longer needs the value skip — `--v3` is injected
      # unconditionally, with no subcommand gate to confuse. These pin that the
      # injection survives argv shapes that used to matter, so a future gated
      # launcher flag cannot quietly reintroduce the bug. The skip itself is
      # still exercised below, by the chat binary's `--trust-tools` gate, and
      # here by the `acp` engine gate: reading `acp` as the subcommand in
      # `--agent acp` would append `--agent-engine=v3` to a bare launch.
      expect "--agent VALUE is a bare launch"     '--v3|--agent|acp'      "$V" --agent acp
      expect "--agent=VALUE is a bare launch"     '--v3|--agent=acp'      "$V" --agent=acp
      expect "a later chat still parses"          '--v3|--agent|a|chat'   "$V" --agent a chat
      expect "--resume-id VALUE is a bare launch" '--v3|--resume-id|s1'   "$V" --resume-id s1
      expect "-r is a bare launch"                '--v3|-r'               "$V" -r

      # ── idempotence: a caller's own flag is never doubled ───────────────────
      # `--v3` aborts with "cannot be used multiple times".
      expect "caller's --v3 not doubled"    'chat|--v3'                 "$V" chat --v3
      expect "caller's --v3 on acp"         'acp|--v3|--agent-engine=v3' "$V" acp --v3
      # A caller may still pass --tui by hand; the wrapper must leave it alone
      # rather than treat it as its own.
      expect "caller's own --tui passes through" '--v3|chat|--tui'      "$V" chat --tui
      # Exact-token match, not a substring scan of "$*": a prompt that merely
      # mentions the flag must not suppress the real one.
      expect "a prompt naming --v3 still gets it" \
        '--v3|chat|explain --v3' "$V" chat 'explain --v3'

      # ── `--` parks the scan; --v3 is global so it still leads ───────────────
      expect "-- still gets --v3"           '--v3|--'                   "$V" --

      # ── acp names its engine, once, and only when the caller did not ────────
      # 3.0.0 `acp` takes the engine from `--agent-engine`, then a setting, then
      # a default that is v2 for any listed client or conflicting option; the
      # global `--v3` is not an input. `chat` and the bare launch keep taking
      # the global alone, so an `acp`-only gate that leaked to them would add a
      # second selector there. A repeated `--agent-engine` aborts upstream with
      # "cannot be used multiple times" (2.x), so a caller's own is never
      # doubled. Appended, never prepended: it is an `acp` option, not a global.
      expect "v3: chat gets no --agent-engine"      '--v3|chat'          "$V" chat
      expect "v3: mcp gets no --agent-engine"       '--v3|mcp|list'      "$V" mcp list
      expect "v3: caller's --agent-engine=v3 is not doubled" \
        '--v3|acp|--agent-engine=v3'                                      "$V" acp --agent-engine=v3
      expect "v3: caller's --agent-engine v3 is not doubled" \
        '--v3|acp|--agent-engine|v3'                                      "$V" acp --agent-engine v3
      # An explicit v2 is the escape hatch: nothing is added behind it.
      expect "v3: explicit --agent-engine=v2 is left alone" \
        '--v3|acp|--agent-engine=v2'                                      "$V" acp --agent-engine=v2
      expect "v3: explicit --agent-engine v2 is left alone" \
        '--v3|acp|--agent-engine|v2'                                      "$V" acp --agent-engine v2
      # A conflicting option still reaches upstream, which refuses it under v3.
      # Dropping the engine here to dodge that would run v2 behind the user's
      # `ai.kiro.cli.v3`, which is the downgrade this selector exists to stop.
      expect "v3: acp --model keeps its engine and its option" \
        '--v3|acp|--model|x|--agent-engine=v3'                            "$V" acp --model x

      # ── --trust-tools is APPENDED, for chat/acp/bare only ───────────────────
      # Opposite case to the globals: --trust-tools belongs to the chat
      # arguments, which other subcommands do not declare. The temporary
      # `kiro-cli-chat` alias runs the same 3.0.0 binary as `kiro-cli`, so its
      # bare launch is a `kiro-cli` bare launch and gets the grant too.
      expect "chat gets --trust-tools"      'chat|--trust-tools=fs_read,@srv'  "$T" chat
      expect "acp gets --trust-tools"       'acp|--trust-tools=fs_read,@srv'   "$T" acp
      expect "bare alias gets --trust-tools" '--trust-tools=fs_read,@srv'      "$T"
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

      # ── kiro-cli carries the grant, gated on the EFFECTIVE engine ───────────
      # 3.0.0 runs the chat implementation inside `kiro-cli`, so its wrapper
      # appends --trust-tools after its own --v3 prepend. v3 rejects the flag on
      # `acp` ("not supported with --agent-engine=v3"), so the gate withholds
      # there when the last --agent-engine before `--` says v3, or, with no
      # --agent-engine, when an exact --v3 token is present — injected or typed.
      # A caller's --agent-engine beats --v3, as the binary resolves it.
      expect "v3+trust: acp withheld (injected engine)" '--v3|acp|--agent-engine=v3'  "$LV" acp
      expect "v3+trust: acp --model withheld, engine kept" \
        '--v3|acp|--model|x|--agent-engine=v3' "$LV" acp --model x
      expect "v3+trust: chat gets it"                  '--v3|chat|--trust-tools=fs_read' "$LV" chat
      expect "v3+trust: bare launch gets it"           '--v3|--trust-tools=fs_read'   "$LV"
      expect "v3+trust: mcp gets none"                 '--v3|mcp|list'                "$LV" mcp list
      expect "v3+trust: caller opts out -> trust returns" \
        '--v3|acp|--agent-engine=v2|--trust-tools=fs_read' "$LV" acp --agent-engine=v2
      expect "v3+trust: caller opts out (two-token form)" \
        '--v3|acp|--agent-engine|v2|--trust-tools=fs_read' "$LV" acp --agent-engine v2
      expect "v3+trust: caller re-asks for v3 -> withheld" \
        '--v3|acp|--agent-engine|v3' "$LV" acp --agent-engine v3
      expect "v3+trust: chat is unaffected by the engine" \
        '--v3|chat|--agent-engine=v3|--trust-tools=fs_read' "$LV" chat --agent-engine=v3
      # The scan is the same one the gate uses for both selectors: a --v3 or
      # --agent-engine past `--` is a positional, not an engine selection.
      # The engine appended behind `--` is as inert as the typed one; `acp`
      # takes no positionals, so this argv fails upstream either way.
      expect "v3+trust: -- ends the scan, injected --v3 still counts" \
        '--v3|acp|--|--agent-engine=v3|--agent-engine=v3' "$LV" acp -- --agent-engine=v3
      expect "-- ends the engine scan" \
        'acp|--|--agent-engine=v3|--trust-tools=fs_read' "$L2" acp -- --agent-engine=v3
      expect "-- ends the --v3 scan" \
        'acp|--|--v3|--trust-tools=fs_read' "$L2" acp -- --v3

      # ── an option VALUE is never read as the subcommand ─────────────────────
      # `--agent acp` is a bare launch: reading `acp` as the subcommand would
      # withhold the grant from what is really a chat launch.
      expect "value skip: --agent VALUE is a bare launch" \
        '--v3|--agent|acp|--trust-tools=fs_read' "$LV" --agent acp
      expect "value skip: --model VALUE is a bare launch" \
        '--v3|--model|m|--trust-tools=fs_read' "$LV" --model m
      expect "value skip: --agent-engine VALUE then acp" \
        '--v3|--agent-engine|v2|acp|--trust-tools=fs_read' "$LV" --agent-engine v2 acp

      # ── a prompt passed to a bare launch is WITHHELD, by design ─────────────
      # A first positional that is not a subcommand cannot be told from an
      # unknown subcommand without a curated subcommand list, so the gate
      # treats it as one and appends nothing; `kiro-cli chat <prompt>` is the
      # form that carries the grant. Pinned so a change to this is deliberate.
      expect "bare launch with a prompt gets none" \
        '--v3|offline prompt' "$LV" 'offline prompt'
      expect "chat with a prompt gets it" \
        '--v3|chat|offline prompt|--trust-tools=fs_read' "$LV" chat 'offline prompt'

      # ── an EXPLICIT --v3 withholds without any v3 config ────────────────────
      expect "no-v3 config: acp keeps trust"           'acp|--trust-tools=fs_read'    "$L2" acp
      # No v3 config, so neither selector is injected: only the caller's counts.
      expect "no-v3 config: caller's --v3 withholds"   '--v3|acp'                     "$L2" --v3 acp
      expect "no-v3 config: caller's --agent-engine=v3 withholds" \
        'acp|--agent-engine=v3' "$L2" acp --agent-engine=v3
      expect "no-v3 config: caller picks v1 -> trust kept" \
        'acp|--agent-engine=v1|--trust-tools=fs_read' "$L2" acp --agent-engine=v1
      expect "no-v3 config: --agent-engine v2 beats --v3" \
        '--v3|acp|--agent-engine=v2|--trust-tools=fs_read' "$L2" --v3 acp --agent-engine=v2

      # ── the alias under a v3 config is NOT given --v3 ───────────────────────
      # The configured --v3 belongs to `kiro-cli`; an alias invocation selects
      # its engine itself, so with no selector the grant stays.
      expect "v3 config: alias acp keeps --trust-tools" \
        'acp|--trust-tools=fs_read' ${trustV3Wrapped}/bin/kiro-cli-chat acp
      expect "v3 config: alias with explicit --v3 acp withholds" \
        '--v3|acp' ${trustV3Wrapped}/bin/kiro-cli-chat --v3 acp

      # ── the Linux composition: --v3 outside the FHS root, trust inside ──────
      # The outer wrapper prepends --v3, the FHS command reaches the payload's
      # trust wrapper, and that wrapper (built with v3 = false) sees the
      # injected token in argv and withholds on acp. Same argv as the
      # direct-wrapper rows above, which is the point.
      expect "fhs v3+trust: acp withheld (injected engine)" \
        '--v3|acp|--agent-engine=v3' "$FV" acp
      expect "fhs v3+trust: chat gets it"                 '--v3|chat|--trust-tools=fs_read' "$FV" chat
      expect "fhs v3+trust: bare launch gets it"          '--v3|--trust-tools=fs_read'     "$FV"
      expect "fhs v3+trust: caller opts out -> trust returns" \
        '--v3|acp|--agent-engine=v2|--trust-tools=fs_read' "$FV" acp --agent-engine=v2
      expect "fhs v3+trust: alias acp keeps --trust-tools" \
        'acp|--trust-tools=fs_read' ${fhsTrustV3}/bin/kiro-cli-chat acp
      expect "fhs no-v3: acp keeps trust"                 'acp|--trust-tools=fs_read'      "$F2" acp
      expect "fhs no-v3: caller's --v3 withholds"         '--v3|acp'                       "$F2" --v3 acp
      expect "fhs no-v3: caller's --agent-engine v3 withholds" \
        'acp|--agent-engine|v3' "$F2" acp --agent-engine v3
      ${
        if trustInsideFhs
        then ''
          # Linux: the grant must live in the payload, not the outer wrapper.
          if grep -qF -- '--trust-tools=' "$(readlink -f "$FV")"; then
            bad "fhs: outer kiro-cli wrapper carries --trust-tools; the payload should"
          else
            ok "fhs: outer kiro-cli wrapper leaves --trust-tools to the payload"
          fi
        ''
        else ''
          if grep -qF -- '--trust-tools=' "$(readlink -f "$FV")"; then
            ok "fhs seam unused off Linux: outer kiro-cli wrapper carries --trust-tools"
          else
            bad "fhs seam unused off Linux, yet the outer wrapper lacks --trust-tools"
          fi
        ''
      }

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

# Behavioral test for packages/copilot-cli/lib/wrapPackage.nix — the argv and
# env the copilot wrapper actually forwards.
#
# Two defects shipped here, one per backend, and NEITHER was visible from the
# Nix side because the generated script is well-formed either way:
#
#   1. an unescaped `$HOME` was expanded by the BUILDER's shell, so the shipped
#      wrapper pointed at `/homeless-shelter/.copilot/mcp-config.json`
#   2. the value lacked the `@` prefix that marks it a FILE PATH, so copilot
#      parsed the path string itself as JSON
#
# They masked each other — JSON parsing failed before anything opened the path,
# so the bogus path never got to report ENOENT — and `--version` / `--help` kept
# working, which is why a "does it start?" check missed both.
#
# The module-eval checks that replaced them grepped the realized wrapper. That
# is strictly better than an eval-level assertion, but a grep proves only that
# a STRING is present. It cannot prove the root var still expands at LAUNCH
# rather than at build (a frozen `/homeless-shelter/...` and a live
# `${HOME}/...` are both "present"), and it cannot prove the value survives as
# a single argv token — which the wrapper depends on, because makeWrapper
# splices `--add-flags` values UNQUOTED.
#
# So this runs the real wrapper against a stub that prints its argv, under a
# CONTROLLED HOME / DEVENV_ROOT. The decisive assertions are the paired ones:
# the same wrapper is invoked twice with different roots and must report a
# different path each time. A build-time-frozen path cannot pass both.
#
# Argv SEMANTICS live here. That the MODULE points the flag at the same
# relative path it renders mcp-config.json to is a separate, wiring-level
# question, asserted in checks/module-eval.nix.
{
  lib,
  pkgs,
  ...
}: let
  wrapCopilotPackage = import ../packages/copilot-cli/lib/wrapPackage.nix {inherit lib pkgs;};

  # Stand-in for the real copilot-cli: prints the argv it received (one ARG
  # line per token, so an empty or space-bearing argument stays unambiguous)
  # plus one baked env var, which is how the `--set` export path is asserted.
  # `${COPILOT_MODEL-unset}` keeps its default so the `-u` in strict mode
  # reports an unbaked env var rather than aborting the stub.
  echoArgv = pkgs.writeShellScript "copilot-cli-stub-argv" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    printf 'ENV=%s\n' "''${COPILOT_MODEL-unset}"
    for cop_a in "$@"; do printf 'ARG=%s\n' "$cop_a"; done
  '';
  stubPackage = pkgs.runCommandLocal "copilot-cli-stub" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    ln -s ${echoArgv} "$out/bin/copilot"
  '';

  wrap = args: wrapCopilotPackage ({package = stubPackage;} // args);

  # The two backends' real parameterization. `configDir` values mirror the
  # module defaults: `.copilot` under HM (copilot's own home dir) and
  # `.config/github-copilot` under devenv (wrapper-aimed, project-relative).
  hmMcp = wrap {
    rootVar = "HOME";
    configDir = ".copilot";
    mcp = true;
  };
  hmMcpEnv = wrap {
    rootVar = "HOME";
    configDir = ".copilot";
    mcp = true;
    environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
  };
  hmEnvOnly = wrap {
    rootVar = "HOME";
    configDir = ".copilot";
    environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
  };
  devenvMcp = wrap {
    rootVar = "DEVENV_ROOT";
    configDir = ".config/github-copilot";
    mcp = true;
  };
  # Nothing to wrap ⇒ the raw package comes back, so a consumer with no MCP
  # servers and no env vars pays for no rebuild.
  unwrapped = wrap {
    rootVar = "HOME";
    configDir = ".copilot";
  };
in
  pkgs.runCommandLocal "copilot-wrapper-argv-check" {
    nativeBuildInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    pass=0
    fail=0
    ok() { pass=$((pass + 1)); echo "ok   - $1"; }
    bad() { fail=$((fail + 1)); echo "FAIL - $1" >&2; }

    # argv <home> <devenv_root> <bin> [args…] -> forwarded tokens joined with '|'
    argv() {
      local home="$1" devenvRoot="$2" bin="$3"
      shift 3
      HOME="$home" DEVENV_ROOT="$devenvRoot" "$bin" "$@" | sed -n 's/^ARG=//p' | paste -sd'|' -
    }

    # baked <home> <devenv_root> <bin> -> the stub's view of COPILOT_MODEL
    baked() {
      local home="$1" devenvRoot="$2" bin="$3"
      HOME="$home" DEVENV_ROOT="$devenvRoot" "$bin" | sed -n 's/^ENV=//p'
    }

    # expect <label> <expected> <home> <devenv_root> <bin> [args…]
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

    HA=/tmp/cop-home-a
    HB=/tmp/cop-home-b
    RA=/tmp/cop-root-a
    RB=/tmp/cop-root-b

    # ── the root var expands at LAUNCH, not at build ────────────────────────
    # This is the regression that mattered. Invoking ONE wrapper under two
    # different roots and demanding two different answers is what separates a
    # live `''${HOME}` from a path the builder already froze — a grep for the
    # literal text cannot tell those apart, and the frozen form was what
    # shipped (`/homeless-shelter/.copilot/mcp-config.json`).
    #
    # The `|` in the expected value is also load-bearing: it proves the flag
    # and its value arrive as TWO argv tokens, i.e. that makeWrapper really
    # does splice `--add-flags` unquoted, and that `@<path>` is not itself
    # split apart.
    expect "HM: flag tracks HOME (a)" \
      "--additional-mcp-config|@$HA/.copilot/mcp-config.json" \
      "$HA" "$RA" ${hmMcp}/bin/copilot
    expect "HM: same wrapper tracks a DIFFERENT HOME (b)" \
      "--additional-mcp-config|@$HB/.copilot/mcp-config.json" \
      "$HB" "$RA" ${hmMcp}/bin/copilot

    expect "devenv: flag tracks DEVENV_ROOT (a)" \
      "--additional-mcp-config|@$RA/.config/github-copilot/mcp-config.json" \
      "$HA" "$RA" ${devenvMcp}/bin/copilot
    expect "devenv: same wrapper tracks a DIFFERENT DEVENV_ROOT (b)" \
      "--additional-mcp-config|@$RB/.config/github-copilot/mcp-config.json" \
      "$HA" "$RB" ${devenvMcp}/bin/copilot

    # The builder's own HOME must never appear, under any invocation.
    if argv "$HA" "$RA" ${hmMcp}/bin/copilot | grep -qF '/homeless-shelter'; then
      bad "HM: builder HOME leaked into the shipped wrapper"
    else
      ok "HM: no builder HOME in the forwarded argv"
    fi

    # ── user argv is appended AFTER the injection ───────────────────────────
    expect "HM: user args follow the injected flag" \
      "--additional-mcp-config|@$HA/.copilot/mcp-config.json|-p|hi there" \
      "$HA" "$RA" ${hmMcp}/bin/copilot -p 'hi there'

    # ── environmentVariables reach the process, not just the Nix string ─────
    # The HM module's only export mechanism is this wrapper, and until now
    # nothing asserted the `--set` args survived postBuild at all — the same
    # build-time blind spot the two shipped defects lived in.
    got="$(baked "$HA" "$RA" ${hmMcpEnv}/bin/copilot)"
    if [ "$got" = "claude-sonnet-4" ]; then
      ok "HM: environmentVariables are exported to the process"
    else
      bad "HM: environmentVariables not exported: want [claude-sonnet-4] got [$got]"
    fi

    # Env without MCP still wraps (HM has no other export path) but must inject
    # NO argv — a stray flag here would reach copilot on every invocation.
    expect "HM: env-only wrapper injects no argv" "" \
      "$HA" "$RA" ${hmEnvOnly}/bin/copilot
    got="$(baked "$HA" "$RA" ${hmEnvOnly}/bin/copilot)"
    if [ "$got" = "claude-sonnet-4" ]; then
      ok "HM: env-only wrapper still exports"
    else
      bad "HM: env-only wrapper did not export: want [claude-sonnet-4] got [$got]"
    fi

    # ── nothing to wrap ⇒ the raw package, byte for byte ────────────────────
    if [ "${unwrapped}" = "${stubPackage}" ]; then
      ok "no MCP and no env returns the unwrapped package"
    else
      bad "unwrapped case built a wrapper: got ${unwrapped}"
    fi

    echo "copilot-wrapper-argv: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    touch "$out"
  ''

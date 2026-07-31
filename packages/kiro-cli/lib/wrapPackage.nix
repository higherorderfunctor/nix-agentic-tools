# Wrap kiro-cli so it launches the way the config asks — shared by BOTH backends
# (DRY). Returns the raw package when nothing needs wrapping.
#
# `environmentVariables` are baked as `export`s only when the backend has no
# native export path — HM passes them here (symlinkJoin is its only export
# mechanism); devenv passes `{}` because it exports via its native `env`
# attrset, but STILL needs the flag injection so `devenv shell` launches the v3
# TUI exactly like HM does.
#
# ── The argv contract ──────────────────────────────────────────────────────
# `--tui` and `--v3` are LAUNCHER-GLOBAL options, so they are injected BEFORE
# any subcommand. Appending them instead is what made `kiro-cli acp` die with
# "error: unexpected argument '--tui' found" — the flag was in the wrong argv
# POSITION, not unsupported by `acp`. Prepended, every subcommand accepts them.
#
# `--trust-tools` is different in kind: the chat binary declares it on the
# `chat` and `acp` SUBCOMMANDS and not at top level, so it is appended and
# gated. Do not "make these consistent" — they are opposite cases.
#
# Measured against kiro-cli 2.15.2; see packages/kiro-cli/docs/launcher-argv.md
# for the probe transcript and how to re-measure on a version bump.
{
  lib,
  pkgs,
}: let
  inherit
    (import ../../../lib/idempotentFlags.nix {inherit lib;})
    bareInvocation
    gateOnSubcommand
    idempotentFlagBlock
    optionValueBlock
    ;

  # kiro-cli's only value-taking top-level options — their values must not be
  # mistaken for a subcommand (`kiro-cli --agent acp` is a bare launch, not the
  # `acp` subcommand). The chat binary has no top-level `--agent`, only
  # `--resume-id`.
  launcherValueFlags = ["--agent" "--resume-id"];
  chatValueFlags = ["--resume-id"];
in
  {
    package,
    tui,
    v3,
    trustedMcpTools,
    environmentVariables ? {},
  }: let
    hasEnv = environmentVariables != {};
    hasTui = tui;
    hasV3 = v3 || tui;
    hasTrust = trustedMcpTools != [];
    needsWrapper = hasEnv || hasTui || hasTrust || hasV3;
    trustToolsCsv = lib.concatStringsSep "," trustedMcpTools;
    # env baked as `export`s (was makeWrapper `--set`), so the hand-written
    # wrapper can ALSO position the flags. makeWrapper only appends
    # (`--append-flags`) or prepends blindly (`--add-flags`), with no way to
    # skip a flag the caller already passed or to gate one on the subcommand.
    envExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (k: v: "export ${lib.escapeShellArg k}=${lib.escapeShellArg v}")
        environmentVariables);

    # `--v3` is injected for EVERY subcommand, because it is global and because
    # that is what makes it reach `acp`: the launcher rewrites its own `--v3`
    # into `--agent-engine v3` — TWO tokens; the error text's `--agent-engine=v3`
    # is clap's diagnostic formatting, not the argv — on the dispatched
    # subcommand. A caller's explicit
    # `--agent-engine=vN` still wins — upstream resolves that, so this wrapper
    # deliberately implements no precedence of its own.
    v3Block = lib.optionalString hasV3 (idempotentFlagBlock {
      flags = ["--v3"];
      position = "prepend";
    });

    # `--tui` is confined to a bare launch and `chat`. It is inert elsewhere on
    # 2.15.2 (stdout is byte-identical with and without it, and the engine's
    # chatter goes to stderr, so it cannot corrupt `acp`'s JSON-RPC framing) —
    # but it means "launch chat in TUI mode", which is meaningless for a stdio
    # protocol or for `mcp`/`settings`, and inert-today is not a guarantee.
    tuiBlock = lib.optionalString hasTui (gateOnSubcommand {
        subcommands = [bareInvocation "chat"];
        valueFlags = launcherValueFlags;
      } (idempotentFlagBlock {
        flags = ["--tui"];
        position = "prepend";
      }));

    # Emitted v3-then-tui so the prepends compose to `--tui --v3 …`, the pair
    # upstream documents together.
    launcherInjection =
      lib.concatStringsSep "\n"
      (builtins.filter (s: s != "") [v3Block tuiBlock]);

    # `--trust-tools` on the chat binary: appended, and gated to the subcommands
    # that declare it. Not idempotence-guarded — unlike `--tui`, repeating it is
    # accepted rather than fatal.
    #
    # `acp` is conditional, because THE TWO WRAPPERS COMPOSE. The launcher
    # resolves `kiro-cli-chat` through PATH, so in a real profile `kiro-cli acp`
    # runs the launcher wrapper AND then this one:
    #
    #   kiro-cli acp
    #     -> launcher wrapper prepends --v3
    #     -> launcher rewrites --v3 to `--agent-engine v3`, resolves
    #        kiro-cli-chat on PATH -> lands here
    #     -> this wrapper appends --trust-tools
    #     => error: the following arguments are not supported with
    #        --agent-engine=v3: --trust-tools
    #
    # The deciding fact is the EFFECTIVE engine, which only argv knows: a
    # caller's `--agent-engine` overrides the injected `--v3`, so neither
    # direction can be settled at eval time. Both are real and measured:
    #
    #   kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x   -> runs (v2)
    #   kiro-cli      acp --agent-engine=v3 --trust-tools=x   -> CONFLICT
    #
    # So the engine is resolved at runtime, from argv, with `v2` as the
    # fallback — the chat binary's OWN clap default
    # (`--agent-engine <ENGINE> … [default: v2]`), NOT what this Nix config
    # bakes in. That distinction is the whole point: this wrapper cannot assume
    # the launcher wrapper is in the chain. `kiro-cli-chat acp` invoked directly
    # runs the v2 engine however `v3 = true` is set, so defaulting to v3 there
    # withheld `--trust-tools` from a session that would have accepted it.
    #
    # Nothing is lost on the normal path, because the launcher does not merely
    # set a mood — it REWRITES argv. `kiro-cli --v3 acp` arrives here as an
    # explicit `acp --agent-engine v3` (measured), which `nat_engine` reads
    # directly, so the withhold still fires through the token rather than
    # through a guess.
    #
    # Why upstream forbids it there — NOT because v3 dropped the flag; under v3
    # `chat` still honours it. `--trust-tools` is a CLIENT-SIDE knob: kiro's TUI
    # re-emits it onto the downstream ACP argv. Its auto-answer of
    # `allow_always` — including the explicit branch for the v3 "kas" engine —
    # is gated on `--trust-all-tools`, a DIFFERENT flag; `trustTools` occurs
    # exactly once in `tui.js`, in the flag-spec table, and is never read by the
    # approval handler. On the `acp` arm kiro-cli IS the agent and the external
    # ACP client owns that answer, so the flag has nothing agent-side to bind
    # to. Withholding costs little, with one caveat worth stating: under
    # home-manager `trustedMcpTools` is ALSO translated into
    # `settings/permissions.yaml` (`mkPermissionRules`), which the v3 agent
    # reads — but that translation is home-manager-only, so on the devenv
    # backend the withheld grant is not recovered declaratively. The interactive
    # half is an ACP `session/request_permission` round-trip the CLI flag could
    # never have participated in either way. `chat` stays unconditional.
    trustAppend = "set -- \"$@\" ${lib.escapeShellArg "--trust-tools=${trustToolsCsv}"}";
    trustInjection = lib.optionalString hasTrust (
      lib.concatStringsSep "\n" [
        (optionValueBlock {
          flag = "--agent-engine";
          var = "nat_engine";
        })
        (gateOnSubcommand {
            subcommands = ["acp" "chat"];
            valueFlags = chatValueFlags;
          } (lib.concatStringsSep "\n" [
            "if [ \"$nat_sub\" != acp ] || [ \"\${nat_engine:-v2}\" != v3 ]; then"
            "  ${trustAppend}"
            "fi"
          ]))
      ]
    );

    # A strict-mode wrapper: bake env, run `injection`, exec the real bin
    # preserving argv0. The `exec` line's shape is load-bearing beyond this
    # file: probe scripts resolve the real binary by reading it back out of the
    # generated wrapper.
    mkWrapper = name: {
      realBin,
      injection ? "",
    }:
      pkgs.writeShellScript name (
        lib.concatStringsSep "\n" (
          ["set -euETo pipefail" "shopt -s inherit_errexit 2>/dev/null || :"]
          ++ lib.optional (envExports != "") envExports
          ++ lib.optional (injection != "") injection
          ++ ["exec -a \"$0\" ${lib.escapeShellArg realBin} \"$@\""]
        )
      );
  in
    if !needsWrapper
    then package
    else
      pkgs.symlinkJoin {
        name = "kiro-cli-wrapped";
        paths = [package];
        postBuild = ''
          ${lib.optionalString (hasEnv || hasTui || hasV3) ''
            rm -f "$out/bin/kiro-cli"
            ln -s ${mkWrapper "kiro-cli-launcher" {
              realBin = "${package}/bin/kiro-cli";
              injection = launcherInjection;
            }} "$out/bin/kiro-cli"
          ''}
          ${lib.optionalString (hasEnv || hasTrust) ''
            rm -f "$out/bin/kiro-cli-chat"
            ln -s ${mkWrapper "kiro-cli-chat-wrapper" {
              realBin = "${package}/bin/kiro-cli-chat";
              injection = trustInjection;
            }} "$out/bin/kiro-cli-chat"
          ''}
        '';
      }

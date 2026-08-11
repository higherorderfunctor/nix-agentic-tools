# Wrap kiro-cli so it launches the way the config asks — shared by BOTH backends
# (DRY). Returns the raw package when nothing needs wrapping.
#
# `environmentVariables` are baked as `export`s on BOTH backends. devenv used
# to pass `{}` here and export through its native `env` attrset instead; that
# wrote the PROJECT SHELL, handing every variable to the developer's own
# session, so it was retired on 2026-08-10. devenv also still needs the flag
# injection so `devenv shell` launches the v3 TUI exactly like HM does.
#
# ── The argv contract ──────────────────────────────────────────────────────
# `--v3` is a LAUNCHER-GLOBAL option, so it is injected BEFORE any subcommand.
# Appending it instead is what made `kiro-cli acp` die with "error: unexpected
# argument found" — the flag was in the wrong argv POSITION, not unsupported by
# `acp`. Prepended, every subcommand accepts it.
#
# `--trust-tools` is different in kind: the chat binary declares it on the
# `chat` and `acp` SUBCOMMANDS and not at top level, so it is appended and
# gated. Do not "make these consistent" — they are opposite cases.
#
# ── Why there is no `--tui` here ────────────────────────────────────────────
# There used to be an `ai.kiro.tui` option that injected `--tui` and implied
# `--v3`. It was removed. `--tui` selects the new TUI harness for the OLD
# engine, and v3 already uses that harness — so under v3 the flag is redundant,
# and it is going away with v3 anyway. Anyone who still wants it on an older
# engine can pass it on the command line.
#
# The implication was NOT decoration, which is why it cannot simply be dropped
# from a config without also switching to `v3`. Measured on 2.16.0:
#
#   kiro-cli --tui       -> error: Conflicting options: --tui cannot be used
#                           with --agent-engine=v1
#   kiro-cli --tui --v3  -> works
#   kiro-cli-chat chat --tui --agent-engine=v2 -> parses (reaches input check)
#
# The chat binary defaults to **v1** and `--tui` conflicts with it, while the
# launcher injects no engine of its own. So bare `--tui` was always broken and
# `tui = true` only worked because it silently dragged `--v3` along.
#
# That default is v1, not the v2 this file long claimed on the strength of a
# help string. Nothing here depends on the specific value — the trust gate asks
# only "is it v3" — which is why its fallback below is a sentinel rather than a
# version number.
#
# Measured against kiro-cli 2.16.0; see packages/kiro-cli/docs/launcher-argv.md
# for the probe transcript and how to re-measure on a version bump.
{
  lib,
  pkgs,
}: let
  inherit
    (import ../../../lib/idempotentFlags.nix {inherit lib;})
    gateOnSubcommand
    idempotentFlagBlock
    optionValueBlock
    ;

  # Value-taking options whose values must not be mistaken for a subcommand.
  # Only the chat binary's list survives: the launcher-side list existed for the
  # removed `--tui` gate, which was the sole caller that had to distinguish a
  # bare launch (`kiro-cli --agent acp` is a bare launch, not the `acp`
  # subcommand). `--v3` is injected unconditionally and needs no such gate.
  chatValueFlags = ["--resume-id"];
in
  {
    package,
    v3,
    trustedMcpTools,
    environmentVariables ? {},
    secretEnv ? {},
    identityMaterializer ? null,
  }: let
    hasEnv = environmentVariables != {};
    hasSecret = secretEnv != {};
    hasV3 = v3;
    hasTrust = trustedMcpTools != [];
    hasIdentity = identityMaterializer != null;
    needsWrapper = hasEnv || hasSecret || hasTrust || hasV3 || hasIdentity;
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

    # SOPS/agenix secrets read at RUNTIME — the decrypted file is `cat`ed into
    # the env just before `exec`, so the VALUE never enters the world-readable
    # store (only the file PATH does). kiro-cli-chat's MCP client then
    # substitutes `${env:VAR}` into http header values at launch.
    #
    # These are emitted AFTER `envExports` so a secret always wins over a
    # same-named static value rather than being silently overwritten by it.
    #
    # Absolute coreutils path is mandatory (nix-standards): this wrapper can be
    # spawned with a replaced or empty PATH, where a bare `cat` fails and the
    # credential would silently end up empty.
    secretExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (var: cred:
          if (cred.file or null) != null
          then "export ${lib.escapeShellArg var}=\"$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg cred.file})\""
          else "export ${lib.escapeShellArg var}=\"$(${lib.escapeShellArg cred.helper})\"")
        secretEnv);

    # Point the engine at a bundle whose identity sentence has been replaced.
    # Materialization is LAZY (at launch) rather than at activation, because the
    # engine bundle is unpacked from the binary on first use: at activation time
    # on a fresh machine there is nothing to patch yet. It is idempotent and
    # cached, so every later launch is a file test.
    #
    # FAIL-OPEN, deliberately. The materializer writes a reason to stderr and
    # exits non-zero when it cannot resolve a bundle, and the launch then
    # proceeds unpatched. The alternative -- refusing to start -- would let a
    # vendor reshuffle brick the terminal agent over a cosmetic prompt edit,
    # which is a worse failure than an unpatched identity. The stderr line is
    # what keeps it from being SILENT.
    #
    # Exported in BOTH wrappers: the launcher resolves `kiro-cli-chat` through
    # PATH so the variable would normally be inherited, but `kiro-cli-chat`
    # invoked directly is a supported entry point and must patch too.
    identityInjection = lib.optionalString hasIdentity ''
      if nat_kas_server="$(${lib.getExe identityMaterializer})"; then
        export KIRO_KAS_SERVER_PATH="$nat_kas_server"
      fi
    '';

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

    # There is deliberately no `--tui` injection. The option that produced it
    # was REMOVED, not merely defaulted off — see the note at the top of this
    # file for the measurements behind that.
    launcherInjection =
      lib.concatStringsSep "\n"
      (lib.filter (s: s != "") [identityInjection v3Block]);

    # `--trust-tools` on the chat binary: appended, and gated to the subcommands
    # that declare it. Not idempotence-guarded — unlike `--tui`, repeating it is
    # accepted rather than fatal.
    #
    # `acp` is conditional, because THE TWO WRAPPERS COMPOSE. The launcher
    # resolves `kiro-cli-chat` through PATH — ON LINUX; darwin resolves by
    # argv[0] .app bundle discovery instead and never runs this wrapper via
    # the launcher at all (see launcher-argv.md, "darwin resolves by argv[0]
    # bundle discovery") — so in a real Linux profile `kiro-cli acp` runs the
    # launcher wrapper AND then this one:
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
    # So the engine is resolved at runtime, from argv, falling back to THE CHAT
    # BINARY'S OWN default rather than to what this Nix config bakes in. That
    # distinction is the whole point: this wrapper cannot assume the launcher
    # wrapper is in the chain. `kiro-cli-chat acp` invoked directly runs the
    # binary's default engine however `v3 = true` is set, so defaulting to v3
    # here withheld `--trust-tools` from a session that would have accepted it.
    #
    # The fallback token is deliberately a SENTINEL, not a version. All the gate
    # asks is "is the effective engine v3", so any non-v3 value is equivalent —
    # and naming a specific one invites exactly the drift this comment used to
    # carry: it claimed `v2` on the strength of a `[default: v2]` help string,
    # while 2.16.0 actually defaults to v1 (measured: `kiro-cli-chat chat --tui`
    # fails with `--tui cannot be used with --agent-engine=v1`). A sentinel
    # cannot go stale when upstream moves the default again.
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
            "if [ \"$nat_sub\" != acp ] || [ \"\${nat_engine:-unspecified}\" != v3 ]; then"
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
          ++ lib.optional (secretExports != "") secretExports
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
          ${lib.optionalString (hasEnv || hasSecret || hasV3 || hasIdentity) ''
            rm -f "$out/bin/kiro-cli"
            ln -s ${mkWrapper "kiro-cli-launcher" {
              realBin = "${package}/bin/kiro-cli";
              injection = launcherInjection;
            }} "$out/bin/kiro-cli"
          ''}
          ${lib.optionalString (hasEnv || hasSecret || hasTrust || hasIdentity) ''
            rm -f "$out/bin/kiro-cli-chat"
            ln -s ${mkWrapper "kiro-cli-chat-wrapper" {
              realBin = "${package}/bin/kiro-cli-chat";
              injection =
                lib.concatStringsSep "\n"
                (lib.filter (s: s != "") [identityInjection trustInjection]);
            }} "$out/bin/kiro-cli-chat"
          ''}
        '';
      }

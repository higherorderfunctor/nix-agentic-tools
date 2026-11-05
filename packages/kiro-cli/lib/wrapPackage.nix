# Wrap kiro-cli so it launches the way the config asks — shared by BOTH backends
# (DRY). Returns the raw package when nothing needs wrapping.
#
# `environmentVariables` are baked as `export`s on BOTH backends. devenv used
# to pass `{}` here and export through its native `env` attrset instead; that
# wrote the PROJECT SHELL, handing every variable to the developer's own
# session, so it was retired on 2026-08-10. devenv also still needs the flag
# injection so `devenv shell` launches the v3 TUI exactly like HM does.
#
# `extraPackages` is a separate PATH prefix, not another environment-variable
# entry. Keeping it separate lets the generated wrapper prepend store-backed
# tools to either the inherited PATH or an explicit `environmentVariables.PATH`
# without capturing the evaluator's PATH or replacing the caller's environment.
#
# On Linux, `--trust-tools` injection is placed inside the FHS payload: when the
# overlay exposes `withFhsPayload`, this helper wraps the unwrapped payload's
# commands first and asks nixpkgs to rebuild its own FHS package around it, so
# the root's /usr/bin/kiro-cli and /usr/bin/kiro-cli-chat carry the grant. Every
# other export, and the `--v3` prepend, stays outer and is inherited across
# bubblewrap. `useFhsSandbox = false` instead selects the same pinned
# `passthru.unwrapped` payload directly.
#
# ── The argv contract ──────────────────────────────────────────────────────
# `--v3` is a LAUNCHER-GLOBAL option, so it is injected BEFORE any subcommand.
# Appending it instead is what made `kiro-cli acp` die with "error: unexpected
# argument found" — the flag was in the wrong argv POSITION, not unsupported by
# `acp`. Prepended, every subcommand accepts it.
#
# On 3.0.0 `acp` does not read that global at all, so `--agent-engine=v3` is
# appended on `acp` as well; see `acpEngineBlock` below.
#
# `--trust-tools` is different in kind: it belongs to the chat arguments of
# `chat`, `acp` and the bare launch, not to every subcommand, so it is appended
# and gated. Do not "make these consistent" — they are opposite cases.
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
    bareInvocation
    flagPresenceBlock
    gateOnSubcommand
    idempotentFlagBlock
    optionValueBlock
    ;

  usage = import ./usageTracking.nix {inherit lib pkgs;};

  # Value-taking top-level options whose values must not be mistaken for a
  # subcommand: `kiro-cli --agent acp` is a bare launch, not the `acp`
  # subcommand. Sourced from the 3.0.0 binary's chat-argument strings and the
  # TUI's launch-flag table. An unlisted value flag makes its value look like a
  # subcommand, which only withholds `--trust-tools` (fails safe).
  launchValueFlags = [
    "--agent"
    "--agent-engine"
    "--delete-session"
    "--effort"
    "--model"
    "--output-format"
    "--profile"
    "--repo"
    "--resume-id"
    "--session-source"
  ];

  wrapperReasons = {
    environmentDefaults ? {},
    environmentVariables ? {},
    environmentVariablesName ? "ai.environmentVariables / ai.kiro.cli.environmentVariables",
    extraPackages ? [],
    secretEnv ? {},
    trustedMcpTools ? [],
    usageTracking ? {enable = false;},
    v3 ? false,
  }: {
    environmentDefaults = {
      active = environmentDefaults != {};
      name = "ai.proxy / ai.kiro.proxy";
    };
    environmentVariables = {
      active = environmentVariables != {};
      name = environmentVariablesName;
    };
    extraPackages = {
      active = extraPackages != [];
      name = "ai.kiro.cli.extraPackages";
    };
    secrets = {
      active = secretEnv != {};
      name = "ai.mcpServers / ai.kiro.mcpServers credential headers";
    };
    trustedMcpTools = {
      active = trustedMcpTools != [];
      name = "ai.kiro.cli.trustedMcpTools";
    };
    usageTracking = {
      active = usageTracking.enable;
      name = "ai.kiro.cli.usageTracking";
    };
    v3 = {
      active = v3;
      name = "ai.kiro.cli.v3";
    };
  };

  # Build one ordinary wrapper layer around the package passed here. The
  # public function below decides whether that layer belongs outside the
  # upstream FHS package or on its unwrapped payload.
  wrapDirect = {
    package,
    v3,
    trustedMcpTools,
    usageTracking ? {enable = false;},
    environmentDefaults ? {},
    environmentVariables ? {},
    extraPackages ? [],
    secretEnv ? {},
    secretOptionPaths ? {},
  }: let
    reasons = wrapperReasons {
      inherit environmentDefaults environmentVariables extraPackages secretEnv trustedMcpTools usageTracking v3;
    };
    hasEnv = reasons.environmentVariables.active || reasons.environmentDefaults.active;
    hasExtraPackages = reasons.extraPackages.active;
    hasSecret = reasons.secrets.active;
    hasTrust = reasons.trustedMcpTools.active;
    hasV3 = reasons.v3.active;
    hasUsage = reasons.usageTracking.active;
    needsWrapper = lib.any (reason: reason.active) (lib.attrValues reasons);
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

    # Header references resolve at launch; a failed reader aborts before Kiro.
    secretExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (variable: value:
          (import ../../../lib/redact {inherit lib;}).assign {
            inherit pkgs value variable;
            option = secretOptionPaths.${variable} or "ai.kiro.mcpServers";
            export = true;
          })
        secretEnv);

    # The Linux buildFHSEnv wrapper preserves PATH and bind-mounts /nix, so a
    # store-backed prefix survives into the synthesized FHS root even though
    # host /usr is shadowed there. Emit this AFTER the ordinary and secret env
    # exports: an explicit PATH becomes the base, while extraPackages is first
    # at this launcher boundary. Linux FHS startup can prepend its synthesized
    # command directories afterward. The conditional expansion avoids a
    # trailing colon (and therefore an implicit current-directory PATH entry)
    # when PATH is unset or empty.
    pathExport = lib.optionalString hasExtraPackages ''
      export PATH=${lib.escapeShellArg (lib.makeBinPath extraPackages)}''${PATH:+:"$PATH"}
    '';

    # `--v3` is injected for EVERY subcommand, because it is a top-level option
    # and selects the v3 engine for `chat` and the bare launch. `acp` ignores
    # it on 3.0.0 (see `acpEngineBlock`). A caller's explicit
    # `--agent-engine=vN` still wins — upstream resolves that, so this wrapper
    # implements no precedence of its own beyond the gates below, which mirror
    # it.
    v3Block = lib.optionalString hasV3 (idempotentFlagBlock {
      flags = ["--v3"];
      position = "prepend";
    });

    # There is deliberately no `--tui` injection. The option that produced it
    # was REMOVED, not merely defaulted off — see the note at the top of this
    # file for the measurements behind that. Since 3.0.0 `kiro-cli` runs the
    # chat implementation itself rather than dispatching to a chat binary, so
    # its wrapper carries the trust grant too, after the `--v3` prepend.
    #
    # 3.0.0 `acp` never reads the top-level `--v3`. It takes `acp
    # --agent-engine`, then the `acp.agentEngine` setting, then a default that
    # is v2 whenever --agent/--model/--effort/--trust-all-tools/--trust-tools
    # is given or the initialize names a client on the built-in v2 list. So
    # `ai.kiro.cli.v3` names the engine on `acp` itself, unless the caller
    # chose one. It is appended: `--agent-engine` is an `acp` option, not a
    # global. It runs before `trustInjection`, whose scan then sees it and
    # withholds the grant.
    acpEngineBlock = lib.optionalString hasV3 (gateOnSubcommand {
        subcommands = ["acp"];
        valueFlags = launchValueFlags;
      } (lib.concatStringsSep "\n" [
        engineScan
        "if [ -z \"$nat_engine\" ]; then set -- \"$@\" --agent-engine=v3; fi"
      ]));
    launcherInjection = lib.concatStringsSep "\n" (lib.filter (block: block != "") [v3Block acpEngineBlock trustInjection]);

    # `--trust-tools`: appended, and gated to `chat`, `acp` and the bare
    # launch. Not idempotence-guarded — repeating it is accepted rather than
    # fatal. A first positional that is not a subcommand (a prompt passed to a
    # bare launch) cannot be told apart from an unknown subcommand without a
    # curated list that would drift every release, so it is treated as a
    # subcommand and the grant is withheld; `kiro-cli chat <prompt>` gets it.
    #
    # `acp` is conditional: an explicit `--agent-engine=v3` rejects
    # `--trust-tools` there with "the following arguments are not supported
    # with --agent-engine=v3", and KAS takes no trust flag anyway. On `acp`
    # kiro-cli IS the agent and the external ACP client owns the approval
    # answer, so the flag has nothing agent-side to bind to. Appending it to an
    # `acp` with no engine selector would also flip upstream's default engine
    # to v2, so the grant is withheld whenever the engine is v3.
    #
    # The deciding fact is the EFFECTIVE engine, which only argv knows: the
    # last `--agent-engine` before `--` wins, including the one `acpEngineBlock`
    # appended; otherwise an exact `--v3` token (injected by the `kiro-cli`
    # wrapper or typed by the caller) selects v3; otherwise the engine is a
    # sentinel, never a guess at the binary's own default. Both directions are
    # real and were measured on 2.x; `kiro-kas-dispatch` re-asserts the v3
    # conflict and the unselected `acp` parse against the 3.0.0 binary:
    #
    #   kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x   -> runs (v2)
    #   kiro-cli acp --agent-engine=v3 --trust-tools=x        -> CONFLICT
    #
    # Under home-manager `trustedMcpTools` is ALSO translated into
    # `settings/permissions.yaml` (`mkPermissionRules`), which the v3 agent
    # reads; that translation is home-manager-only, so on the devenv backend
    # the withheld grant is not recovered declaratively. `chat` and the bare
    # launch are unconditional.
    engineScan = optionValueBlock {
      flag = "--agent-engine";
      var = "nat_engine";
    };
    v3Scan = flagPresenceBlock {
      flag = "--v3";
      var = "nat_v3";
    };
    # The configured v3 flag belongs only to the `kiro-cli` wrapper. A
    # `kiro-cli-chat` invocation must establish v3 itself, by either selector.
    usageEngineGuard = requireExplicitV3:
      lib.optionalString hasUsage ''
        ${engineScan}
        if [ -n "$nat_engine" ] && [ "$nat_engine" != v3 ]; then
          printf '%s\n' 'Kiro usage tracking requires the v3 engine; remove the non-v3 --agent-engine override or disable usageTracking.' >&2
          exit 1
        fi
        ${lib.optionalString requireExplicitV3 ''
          ${v3Scan}
          if [ "$nat_engine" != v3 ] && [ "$nat_v3" != 1 ]; then
            printf '%s\n' 'Kiro usage tracking requires an explicit v3 engine for kiro-cli-chat; pass --agent-engine v3 or --v3, or use kiro-cli.' >&2
            exit 1
          fi
        ''}
      '';
    trustAppend = "set -- \"$@\" ${lib.escapeShellArg "--trust-tools=${trustToolsCsv}"}";
    # Scans run here, after the `--v3` prepend and the `acp` engine append, so
    # both injected selectors count.
    trustInjection = lib.optionalString hasTrust (
      lib.concatStringsSep "\n" [
        engineScan
        v3Scan
        "nat_trust_engine=\"$nat_engine\""
        "if [ -z \"$nat_trust_engine\" ] && [ \"$nat_v3\" = 1 ]; then nat_trust_engine=v3; fi"
        (gateOnSubcommand {
            subcommands = ["acp" "chat" bareInvocation];
            valueFlags = launchValueFlags;
          } (lib.concatStringsSep "\n" [
            "if [ \"$nat_sub\" != acp ] || [ \"\${nat_trust_engine:-unspecified}\" != v3 ]; then"
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
      requireExplicitV3 ? false,
    }:
      pkgs.writeShellScript name (
        lib.concatStringsSep "\n" (
          ["set -euETo pipefail" "shopt -s inherit_errexit 2>/dev/null || :"]
          ++ lib.optional (envExports != "") envExports
          ++ lib.optional (environmentDefaults != {}) (import ../../../lib/ai/environment-defaults.nix {inherit lib;} environmentDefaults)
          ++ lib.optionals (secretExports != "") [
            ''export PATH="''${PATH-${pkgs.coreutils}/bin}"''
            secretExports
          ]
          ++ lib.optional (pathExport != "") pathExport
          ++ lib.optionals hasUsage [(usageEngineGuard requireExplicitV3) (usage.launcherBlock usageTracking)]
          ++ lib.optional (injection != "") injection
          ++ ["exec -a \"$0\" ${lib.escapeShellArg realBin} \"$@\""]
        )
      );
  in
    assert lib.assertMsg (!hasUsage || hasV3) "Kiro usage tracking requires v3 = true in the managed wrapper.";
    assert lib.assertMsg (!hasUsage || usage.pythonRequirement.assertion) usage.pythonRequirement.message;
      if !needsWrapper
      then package
      else
        pkgs.symlinkJoin {
          name = "kiro-cli-wrapped";
          paths = [package] ++ lib.optional hasUsage (usage.tool usageTracking);
          postBuild = ''
            ${lib.optionalString (hasEnv || hasExtraPackages || hasSecret || hasTrust || hasUsage || hasV3) ''
              rm -f "$out/bin/kiro-cli"
              ln -s ${mkWrapper "kiro-cli-launcher" {
                realBin = "${package}/bin/kiro-cli";
                injection = launcherInjection;
              }} "$out/bin/kiro-cli"
            ''}
            ${lib.optionalString (hasEnv || hasExtraPackages || hasSecret || hasTrust || hasUsage) ''
              rm -f "$out/bin/kiro-cli-chat"
              ln -s ${mkWrapper "kiro-cli-chat-wrapper" {
                realBin = "${package}/bin/kiro-cli-chat";
                injection = trustInjection;
                requireExplicitV3 = true;
              }} "$out/bin/kiro-cli-chat"
            ''}
          '';
        };
in {
  inherit wrapperReasons;

  wrapPackage = {
    package,
    v3,
    trustedMcpTools,
    usageTracking ? {enable = false;},
    environmentDefaults ? {},
    environmentVariables ? {},
    extraPackages ? [],
    secretEnv ? {},
    useFhsSandbox ? true,
    secretOptionPaths ? {},
  }: let
    # Re-compose the upstream Linux FHS package around a trust-wrapped
    # payload, so --trust-tools lives at the root's /usr/bin command paths.
    # The inner wrapper is built with `v3 = false`; it still withholds on
    # `acp` because the outer wrapper's `--v3` prepend and `--agent-engine=v3`
    # append reach it in argv.
    # Other exports remain outside: they are inherited across bubblewrap and
    # retain their established precedence.
    placeTrustInsideFhs =
      useFhsSandbox
      && pkgs.stdenv.hostPlatform.isLinux
      && trustedMcpTools != []
      && package ? unwrapped
      && package ? withFhsPayload;
    innerTrustPackage =
      (wrapDirect {
        package = package.unwrapped;
        v3 = false;
        inherit trustedMcpTools;
      }).overrideAttrs (_: {
        # nixpkgs' FHS expression inherits these from its payload. Ordinary
        # outer wrappers do not need them, so surface them only on this inner
        # package and leave every existing wrapper derivation unchanged.
        inherit (package.unwrapped) meta version;
      });
    selectedPackage =
      if !useFhsSandbox
      then package.unwrapped or package
      else if placeTrustInsideFhs
      then package.withFhsPayload innerTrustPackage
      else package;
  in
    wrapDirect {
      package = selectedPackage;
      inherit environmentDefaults environmentVariables extraPackages secretEnv secretOptionPaths usageTracking v3;
      trustedMcpTools =
        if placeTrustInsideFhs
        then []
        else trustedMcpTools;
    };
}

# Wrap kiro-cli so it launches the v3 engine — shared by BOTH backends (DRY).
#
# `environmentVariables` are baked as `export`s on BOTH backends. devenv used
# to pass `{}` here and export through its native `env` attrset instead; that
# wrote the PROJECT SHELL, handing every variable to the developer's own
# session, so it was retired on 2026-08-10.
#
# `extraPackages` is a separate PATH prefix, not another environment-variable
# entry. Keeping it separate lets the generated wrapper prepend store-backed
# tools to either the inherited PATH or an explicit `environmentVariables.PATH`
# without capturing the evaluator's PATH or replacing the caller's environment.
#
# On Linux the wrapper sits OUTSIDE nixpkgs' FHS package; every export it
# makes is inherited across bubblewrap. `useFhsSandbox = false` instead wraps
# the same pinned `passthru.unwrapped` payload directly.
#
# ── The argv contract (kiro-cli 3.0.0) ─────────────────────────────────────
# `--v3` is a LAUNCHER-GLOBAL option, prepended before any subcommand. Without
# it the bare launch and `chat` follow the `chat.agentEngine` setting and the
# binary's upgrade state, which 3.0.0 moves either way ("you can try V3 any
# time with kiro-cli --v3" in the Rust strings, "Back to V2: … kiro-cli --v2
# for one session" in the TUI); the prepend pins v3 for the session. A
# misplaced global is what once made `kiro-cli acp` die with "unexpected
# argument": the position, not the flag, was wrong.
#
# `acp` never reads that global. It resolves its engine from `acp
# --agent-engine`, then the `acp.agentEngine` setting, then a default that is
# v2 whenever `--agent`, `--model`, `--effort`, `--trust-all-tools` or
# `--trust-tools` is given or the initialize names a client on the binary's
# built-in v2 list (`acp-smoke` is one). So `--agent-engine=v3` is appended to
# `acp` unless an `--agent-engine` token is already there; the caller's own
# selector is left to upstream. `kiro-kas-dispatch` measures both facts.
#
# There is no `--trust-tools` injection. Under v3 no process hands the flag to
# KAS, which reads tool policy only from `permissions.yaml`; the bare-launch
# parser rejects it, and `acp --agent-engine=v3` rejects it with a conflict.
# `trustedMcpTools` lowers to `settings/permissions.yaml` in mkKiro.nix, on
# Home Manager only.
#
# See packages/kiro-cli/docs/launcher-argv.md for the measurements.
{
  lib,
  pkgs,
}: let
  inherit
    (import ../../../lib/idempotentFlags.nix {inherit lib;})
    gateOnSubcommand
    idempotentFlagBlock
    optionPresenceBlock
    ;

  usage = import ./usageTracking.nix {inherit lib pkgs;};

  # Value-taking top-level options whose values must not be mistaken for a
  # subcommand: `kiro-cli --agent acp` is a bare launch, not the `acp`
  # subcommand. Sourced from the 3.0.0 binary's chat-argument strings and the
  # TUI's launch-flag table. An unlisted value flag spelled `acp` would make
  # its value look like the subcommand and append `--agent-engine=v3` to a
  # bare launch.
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

  # Options that only reach Kiro through this wrapper. mkKiro.nix reports the
  # ones a consumer set while `package = null` leaves no wrapper to carry them.
  wrapperReasons = {
    environmentDefaults ? {},
    environmentVariables ? {},
    environmentVariablesName ? "ai.environmentVariables / ai.kiro.cli.environmentVariables",
    extraPackages ? [],
    secretEnv ? {},
    usageTracking ? {enable = false;},
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
    usageTracking = {
      active = usageTracking.enable;
      name = "ai.kiro.cli.usageTracking";
    };
  };
in {
  inherit wrapperReasons;

  wrapPackage = {
    package,
    usageTracking ? {enable = false;},
    environmentDefaults ? {},
    environmentVariables ? {},
    extraPackages ? [],
    secretEnv ? {},
    useFhsSandbox ? true,
    secretOptionPaths ? {},
  }: let
    hasUsage = usageTracking.enable;
    selectedPackage =
      if useFhsSandbox
      then package
      else package.unwrapped or package;

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
    pathExport = lib.optionalString (extraPackages != []) ''
      export PATH=${lib.escapeShellArg (lib.makeBinPath extraPackages)}''${PATH:+:"$PATH"}
    '';

    v3Block = idempotentFlagBlock {
      flags = ["--v3"];
      position = "prepend";
    };
    # Appended: `--agent-engine` is an `acp` option, not a global.
    acpEngineBlock =
      gateOnSubcommand {
        subcommands = ["acp"];
        valueFlags = launchValueFlags;
      } (lib.concatStringsSep "\n" [
        (optionPresenceBlock {
          flag = "--agent-engine";
          var = "nat_engine";
        })
        "if [ \"$nat_engine\" = 0 ]; then set -- \"$@\" --agent-engine=v3; fi"
      ]);

    # A strict-mode wrapper: bake env, inject the engine selectors, exec the
    # real bin preserving argv0. The `exec` line's shape is load-bearing beyond
    # this file: probe scripts resolve the real binary by reading it back out
    # of the generated wrapper.
    launcher = pkgs.writeShellScript "kiro-cli-launcher" (
      lib.concatStringsSep "\n" (
        ["set -euETo pipefail" "shopt -s inherit_errexit 2>/dev/null || :"]
        ++ lib.optional (envExports != "") envExports
        ++ lib.optional (environmentDefaults != {}) (import ../../../lib/ai/environment-defaults.nix {inherit lib;} environmentDefaults)
        ++ lib.optionals (secretExports != "") [
          ''export PATH="''${PATH-${pkgs.coreutils}/bin}"''
          secretExports
        ]
        ++ lib.optional (pathExport != "") pathExport
        ++ lib.optional hasUsage (usage.launcherBlock usageTracking)
        ++ [
          v3Block
          acpEngineBlock
          "exec -a \"$0\" ${lib.escapeShellArg "${selectedPackage}/bin/kiro-cli"} \"$@\""
        ]
      )
    );
  in
    assert lib.assertMsg (!hasUsage || usage.pythonRequirement.assertion) usage.pythonRequirement.message;
      pkgs.symlinkJoin {
        name = "kiro-cli-wrapped";
        paths = [selectedPackage] ++ lib.optional hasUsage (usage.tool usageTracking);
        postBuild = ''
          rm -f "$out/bin/kiro-cli"
          ln -s ${launcher} "$out/bin/kiro-cli"
        '';
      };
}

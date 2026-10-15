# Wrap kiro-cli so it launches the way the config asks — shared by BOTH backends
# (DRY). Returns the raw package when nothing needs wrapping.
#
# `environmentVariables` are baked as `export`s on BOTH backends. devenv used
# to pass `{}` here and export through its native `env` attrset instead; that
# wrote the PROJECT SHELL, handing every variable to the developer's own
# session, so it was retired on 2026-08-10. devenv also still needs the flag
# handling so chat trust grants behave consistently on both backends.
#
# `extraPackages` is a separate PATH prefix, not another environment-variable
# entry. Keeping it separate lets the generated wrapper prepend store-backed
# tools to either the inherited PATH or an explicit `environmentVariables.PATH`
# without capturing the evaluator's PATH or replacing the caller's environment.
#
# On post-split Linux, chat-only argv injection is the one wrapper concern that
# cannot remain outside: the FHS root's /usr/bin shadows the outer chat command.
# When the overlay exposes `withFhsPayload`, this helper wraps the unwrapped chat
# payload first and asks nixpkgs to rebuild its own FHS package around it. Every
# other export stays outer and inherited. `useFhsSandbox = false` instead selects
# the same pinned `passthru.unwrapped` payload directly.
#
# Terminal engines come from delivered settings; ACP defaults belong to the
# package's existing build launcher. This layer only adds chat-specific trust.
{
  lib,
  pkgs,
}: let
  wrapperReasons = {
    environmentVariables ? {},
    environmentVariablesName ? "ai.environmentVariables / ai.kiro.cli.environmentVariables",
    extraPackages ? [],
    secretEnv ? {},
    trustedMcpTools ? [],
  }: {
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
  };

  # Build one ordinary wrapper layer around the package passed here. The
  # public function below decides whether that layer belongs outside the
  # upstream FHS package or on its unwrapped payload.
  wrapDirect = {
    package,
    trustedMcpTools,
    environmentVariables ? {},
    extraPackages ? [],
    secretEnv ? {},
    secretOptionPaths ? {},
  }: let
    reasons = wrapperReasons {
      inherit environmentVariables extraPackages secretEnv trustedMcpTools;
    };
    hasEnv = reasons.environmentVariables.active;
    hasExtraPackages = reasons.extraPackages.active;
    hasSecret = reasons.secrets.active;
    hasTrust = reasons.trustedMcpTools.active;
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
    # credential would silently end up empty. Check the assignment before
    # exporting: export itself masks a failed credential reader's exit code.
    # Keep launching, but warn with the consumer option rather than the token.
    #
    # The reader's own stderr passes THROUGH. An interactive helper prompts for
    # a passphrase there, and swallowing it turns a launch that is waiting for
    # input into one that looks hung. Only the value is captured.
    secretExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (var: cred: let
          reader =
            if (cred.file or null) != null
            then "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg cred.file}"
            else lib.escapeShellArg cred.helper;
          optionPath = secretOptionPaths.${var} or "ai.kiro.mcpServers";
        in ''
          if ! nat_mcp_secret="$(${reader})"; then
            printf '%s\n' ${lib.escapeShellArg "WARNING: ${optionPath}: credential reader failed; launching without this MCP credential"} >&2
            nat_mcp_secret=""
          elif [ -z "$nat_mcp_secret" ]; then
            printf '%s\n' ${lib.escapeShellArg "WARNING: ${optionPath}: credential reader returned an empty value; launching without this MCP credential"} >&2
          fi
          export ${lib.escapeShellArg var}="$nat_mcp_secret"
          unset nat_mcp_secret
        '')
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

    # The payload resolves ACP engine settings before applying this grant.
    # Passing it only on the chat entry point preserves launcher dispatch and
    # avoids reading settings in a second wrapper. The payload unsets it before
    # exec so child processes cannot accidentally inherit the grant.
    trustInjection = lib.optionalString hasTrust ''
      export NAT_KIRO_TRUST_TOOLS=${lib.escapeShellArg trustToolsCsv}
    '';

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
          ++ lib.optional (pathExport != "") pathExport
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
          ${lib.optionalString (hasEnv || hasExtraPackages || hasSecret) ''
            rm -f "$out/bin/kiro-cli"
            ln -s ${mkWrapper "kiro-cli-launcher" {
              realBin = "${package}/bin/kiro-cli";
            }} "$out/bin/kiro-cli"
          ''}
          ${lib.optionalString (hasEnv || hasExtraPackages || hasSecret || hasTrust) ''
            rm -f "$out/bin/kiro-cli-chat"
            ln -s ${mkWrapper "kiro-cli-chat-wrapper" {
              realBin = "${package}/bin/kiro-cli-chat";
              injection = trustInjection;
            }} "$out/bin/kiro-cli-chat"
          ''}
        '';
      };
in {
  inherit wrapperReasons;

  wrapPackage = {
    package,
    trustedMcpTools,
    environmentVariables ? {},
    extraPackages ? [],
    secretEnv ? {},
    useFhsSandbox ? true,
    secretOptionPaths ? {},
  }: let
    # The upstream Linux FHS root supplies its own /usr/bin/kiro-cli-chat ahead
    # of the inherited PATH. An outer chat wrapper is therefore unreachable
    # when the launcher dispatches. Re-compose the upstream package around a
    # chat-only wrapped payload so --trust-tools lives at the command path the
    # FHS launcher actually selects. Other exports remain outside: they are
    # inherited across bubblewrap and retain their established precedence.
    placeTrustInsideFhs =
      useFhsSandbox
      && pkgs.stdenv.hostPlatform.isLinux
      && trustedMcpTools != []
      && package ? unwrapped
      && package ? withFhsPayload;
    innerTrustPackage =
      (wrapDirect {
        package = package.unwrapped;
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
      inherit environmentVariables extraPackages secretEnv secretOptionPaths;
      trustedMcpTools =
        if placeTrustInsideFhs
        then []
        else trustedMcpTools;
    };
}

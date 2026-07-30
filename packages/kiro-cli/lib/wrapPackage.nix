# Wrap kiro-cli so it launches the way the config asks — shared by BOTH backends
# (DRY). `--tui`/`--v3` append to the top-level `kiro-cli` launcher IDEMPOTENTLY
# (only if the caller did not already pass them — an unconditional append doubles
# `--tui` and clap aborts); `--trust-tools` appends to the `kiro-cli-chat`
# subcommand. The new TUI is rejected on the legacy engine (`--tui` alone errors;
# `--tui --v3` is the working pair), so tui implies v3. Returns the raw package
# when nothing needs wrapping. `environmentVariables` are baked as `export`s only
# when the backend has no native export path — HM passes them here (symlinkJoin
# is its only export mechanism); devenv passes `{}` because it exports via its
# native `env` attrset, but STILL needs the flag appends so `devenv shell`
# launches the v3 TUI exactly like HM does.
#
# Lifted verbatim out of mkKiro.nix, which was over a thousand lines and gave
# this no seam to test through: a check can import THIS file with a stub package
# and assert on the argv the generated wrappers forward.
{
  lib,
  pkgs,
}: let
  # Idempotent boolean-flag appends for the launcher wrapper (generic helper in
  # lib/; shared with module-eval coverage). See lib/idempotentFlags.nix.
  inherit (import ../../../lib/idempotentFlags.nix {inherit lib;}) idempotentFlagBlock;
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
    # wrapper can ALSO do idempotent `--tui`/`--v3` injection — makeWrapper
    # `--append-flags` can only append unconditionally, which doubles the flag
    # when a caller already passes it (clap then aborts).
    envExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (k: v: "export ${lib.escapeShellArg k}=${lib.escapeShellArg v}")
        environmentVariables);
    launcherFlags = lib.optional hasTui "--tui" ++ lib.optional hasV3 "--v3";
    # A strict-mode wrapper: bake env, idempotently append `flags` (each only if
    # the caller did not already pass it), unconditionally append `trailing`,
    # then exec the real bin preserving argv0.
    mkWrapper = name: {
      realBin,
      flags ? [],
      trailing ? [],
    }:
      pkgs.writeShellScript name (
        lib.concatStringsSep "\n" (
          ["set -euETo pipefail" "shopt -s inherit_errexit 2>/dev/null || :"]
          ++ lib.optional (envExports != "") envExports
          ++ lib.optional (flags != []) (idempotentFlagBlock flags)
          ++ lib.optional (trailing != [])
          "set -- \"$@\" ${lib.concatStringsSep " " (map lib.escapeShellArg trailing)}"
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
              flags = launcherFlags;
            }} "$out/bin/kiro-cli"
          ''}
          ${lib.optionalString (hasEnv || hasTrust) ''
            rm -f "$out/bin/kiro-cli-chat"
            ln -s ${mkWrapper "kiro-cli-chat-wrapper" {
              realBin = "${package}/bin/kiro-cli-chat";
              trailing = lib.optional hasTrust "--trust-tools=${trustToolsCsv}";
            }} "$out/bin/kiro-cli-chat"
          ''}
        '';
      }

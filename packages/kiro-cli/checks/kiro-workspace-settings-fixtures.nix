# The settings extractor runs only selected AST literals from the TUI bundle
# that embedded-tui.py decodes. Probe malformed sources as well as the
# successful symbolic path.
{pkgs, ...}: {
  checks = let
    vu = import ../lib/packaging.nix;
  in {
    kiro-tui-extraction = pkgs.runCommandLocal "kiro-tui-extraction-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./embedded-tui.py} ${../extract/embedded-tui.py} ${../extract/embedded-kas.py} \
        ${pkgs.lib.getLib pkgs.zstd}/lib/libzstd${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} ${pkgs.zstd}/bin/zstd
      ${pkgs.coreutils}/bin/touch "$out"
    '';
    kiro-workspace-settings-fixtures = pkgs.runCommandLocal "kiro-workspace-settings-fixtures-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 ${./kiro-settings-fixtures.py} ${vu.kiroSettingsExtractScript pkgs}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}

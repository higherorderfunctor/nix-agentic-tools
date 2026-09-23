# The settings extractor runs only selected AST literals from the materialized
# TUI bundle. Probe malformed sources as well as the successful symbolic path.
{pkgs, ...}: {
  checks = let
    vu = import ../lib/packaging.nix;
  in {
    kiro-tui-materializer-fixtures = pkgs.runCommandLocal "kiro-tui-materializer-fixtures-check" {} ''
      ${pkgs.python3}/bin/python3 ${./kiro-materializer-fixtures.py} \
        ${../extract/embedded-tui.py} ${vu.kiroFakeKasScript pkgs} \
        ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      ${pkgs.coreutils}/bin/touch "$out"
    '';
    kiro-workspace-settings-fixtures = pkgs.runCommandLocal "kiro-workspace-settings-fixtures-check" {} ''
      ${pkgs.python3}/bin/python3 ${./kiro-settings-fixtures.py} ${vu.kiroSettingsExtractScript pkgs}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}

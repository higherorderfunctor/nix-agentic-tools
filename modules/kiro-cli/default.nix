# programs.kiro-cli home-manager module.
# Mirrors upstream programs.claude-code conventions.
# Implementation in Phase 1.2.
{lib, ...}: {
  options.programs.kiro-cli = {
    enable = lib.mkEnableOption "Kiro CLI";
  };
}

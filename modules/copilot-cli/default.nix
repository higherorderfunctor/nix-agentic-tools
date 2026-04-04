# programs.copilot-cli home-manager module.
# Mirrors upstream programs.claude-code conventions.
# Implementation in Phase 1.1.
{lib, ...}: {
  options.programs.copilot-cli = {
    enable = lib.mkEnableOption "GitHub Copilot CLI";
  };
}

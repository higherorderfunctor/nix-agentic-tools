{pkgs, ...}: {
  checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    mcp-oauth-state-refresh =
      pkgs.runCommand "mcp-oauth-state-refresh" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export PYTHONDONTWRITEBYTECODE=1
        export PYTHONPATH=${./.}
        python3 ${./state-refresh.py} ${../src} ${pkgs.ai.mcp-oauth}/bin/mcp-oauth
        python3 ${./lifecycle.py} ${../src} ${pkgs.gum}/bin/gum
        touch "$out"
      '';
  };
}

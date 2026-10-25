{pkgs, ...}: let
  inherit (pkgs) lib;
  package = pkgs.ai.generic.airlock;
  inherit (package) frontend raw;
  fake = pkgs.writeShellScriptBin "airlock" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    if [[ $# -gt 0 ]]; then
      printf '%s\0' "$@"
    fi
  '';
  launcher = package.mkLauncher fake;
  closure = pkgs.closureInfo {rootPaths = [package];};
in {
  checks =
    {
      airlock-web = frontend;

      airlock-web-closure =
        pkgs.runCommand "airlock-web-closure" {
          nativeBuildInputs = [pkgs.python3];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 - <<'PY'
          from pathlib import Path

          closure = set(Path("${closure}/store-paths").read_text().splitlines())
          assert "${frontend}" in closure, "frontend absent from package closure"
          assert "${raw}" in closure, "raw Rust executable absent from package closure"
          assert Path("${frontend}/index.html").is_file(), "built HTML missing"
          assert any(Path("${frontend}/assets").glob("*.js")), "built JavaScript missing"
          assert any(Path("${frontend}/assets").glob("*.css")), "built CSS missing"
          print("frontend, raw Rust, and static assets present in composed closure")
          PY
          touch "$out"
        '';

      airlock-web-launcher =
        pkgs.runCommand "airlock-web-launcher" {
          nativeBuildInputs = [pkgs.python3];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          python3 - <<'PY'
          import subprocess

          launcher = "${launcher}/bin/airlock"
          cases = (
              ([], []),
              (["check-config", "--config", "a b"], ["check-config", "--config", "a b"]),
              (["usage", "--config", "*", "--json"], ["usage", "--config", "*", "--json"]),
              (["serve", "--config", "a b"], ["serve", "--config", "a b", "--web-root", "${frontend}"]),
              (["serve", "--config", "a b", "--web-root", "/tmp/caller root"], ["serve", "--config", "a b", "--web-root", "/tmp/caller root"]),
              (["serve", "--config", "a b", "--web-root=/tmp/caller root"], ["serve", "--config", "a b", "--web-root=/tmp/caller root"]),
              (["serve", "--config", "a b", "--web-root"], ["serve", "--config", "a b", "--web-root"]),
          )
          for supplied, expected in cases:
              result = subprocess.run([launcher, *supplied], check=True, capture_output=True)
              actual = result.stdout.rstrip(b"\0").decode().split("\0") if result.stdout else []
              assert actual == expected, (supplied, actual, expected)
          print("launcher preserves argv and defaults the serve web root only when absent")
          PY
          touch "$out"
        '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-web-integration = frontend.overrideAttrs (_final: _old: {
        name = "airlock-web-integration";
        AIRLOCK_REAL_BINARY = "${package}/bin/airlock";
        AIRLOCK_WEB_ROOT = "${frontend}";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        checkPhase = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          runHook preCheck
          npm test -- tests/real-server.test.ts
          runHook postCheck
        '';
      });
    };
}

{pkgs, ...}: let
  certificateBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  snapshots = [pkgs.docs.kimchi-docs pkgs.docs.kiro-model-catalog.src pkgs.docs.slack-mcp.src];
in {
  checks.web-docs-fixtures =
    # Both variables must be pinned: OpenSSL prefers NIX_SSL_CERT_FILE, and
    # stdenv otherwise supplies the unreadable /no-cert-file.crt sentinel.
    assert builtins.all (snapshot: snapshot.NIX_SSL_CERT_FILE == certificateBundle && snapshot.SSL_CERT_FILE == certificateBundle) snapshots;
      pkgs.runCommand "web-docs-fixtures" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./snapshot.py} ${../../lib/web-docs/snapshot.py} \
          ${pkgs.docs.kimchi-docs.snapshotConfig} ${pkgs.docs.kimchi-docs} \
          ${pkgs.docs.kiro-model-catalog.src.snapshotConfig} ${pkgs.docs.kiro-model-catalog.src} \
          ${pkgs.nix}/bin/nix ${pkgs.coreutils}/bin/false
        touch "$out"
      '';
}

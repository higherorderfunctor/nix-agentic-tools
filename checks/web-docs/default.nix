{
  harness,
  pkgs,
  ...
}: let
  certificateBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  bundleRows = {
    "kimchi.NIX_SSL_CERT_FILE" = (pkgs.docs.kimchi-docs.NIX_SSL_CERT_FILE or null) == certificateBundle;
  };
in {
  checks.web-docs-fixtures =
    # Pin NIX_SSL_CERT_FILE so the runner uses the bundle instead of falling
    # back from stdenv's unreadable /no-cert-file.crt sentinel. The runner
    # sets SSL_CERT_FILE before starting Python, regardless of its input value.
    assert harness.checkRows "documentation snapshots must use ${certificateBundle}" bundleRows;
      pkgs.runCommand "web-docs-fixtures" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./snapshot.py} ${../../lib/web-docs/snapshot.py} \
          ${pkgs.docs.kimchi-docs.snapshotConfig} ${pkgs.docs.kimchi-docs} \
          ${pkgs.nix}/bin/nix
        touch "$out"
      '';
}

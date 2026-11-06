# The release selector against manifests shaped like Kiro's real one, which
# lists zip, tar.zst and rpm siblings and musl tarballs beside each glibc
# tarball. Expected URLs are written by hand from the manifest's download paths.
{pkgs, ...}: let
  release = import ../lib/release.nix;
  select = release.mkSelectRelease pkgs;
  fixtures = ./fixtures/release-manifest;
in {
  checks.kiro-release-manifest = pkgs.runCommand "kiro-release-manifest" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    jq=${pkgs.jq}/bin/jq

    # Picks the glibc tarball over the musl, zip, tar.zst and rpm entries that
    # share its os and architecture; a selector on fileType alone, or on
    # os/architecture, would pick several.
    ${select} ${fixtures}/manifest.json > selected.json
    [ "$("$jq" -r '.version' selected.json)" = 3.1.0 ]
    [ "$("$jq" -r '.urls."x86_64-linux"' selected.json)" = https://desktop-release.q.us-east-1.amazonaws.com/3.1.0/kirocli-x86_64-linux.tar.gz ]
    [ "$("$jq" -r '.urls."aarch64-darwin"' selected.json)" = https://desktop-release.q.us-east-1.amazonaws.com/3.1.0/kirocli-universal-darwin.tar.gz ]
    [ "$("$jq" '.urls | length' selected.json)" = 2 ]

    # Each refusal names the Nix system, and the manifest's downloads.
    expect_refusal() {
      local fixture="$1" system="$2" reason="$3" status=0
      ${select} "${fixtures}/$fixture.json" > /dev/null 2> err.txt || status=$?
      [ "$status" != 0 ]
      grep -qF "$system" err.txt
      grep -qF "$reason" err.txt
      grep -qF 'manifest downloads:' err.txt
      grep -qF 'kirocli-x86_64-linux-musl.tar.gz' err.txt
    }
    expect_refusal missing-entry x86_64-linux '0 manifest entries match'
    expect_refusal duplicate-entry x86_64-linux '2 manifest entries match'
    expect_refusal stale-download aarch64-darwin 'is not under manifest version 3.1.0'

    touch "$out"
  '';
}

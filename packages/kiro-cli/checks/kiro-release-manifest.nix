# The release selector against a manifest shaped like Kiro's real one, which
# lists zip, tar.zst and rpm siblings and musl tarballs beside each glibc
# tarball. Expected URLs are written by hand from the manifest's download paths.
{pkgs, ...}: let
  release = import ../lib/release.nix;
  select = release.mkSelectRelease pkgs;
  decide = release.mkDecideUpdate pkgs;
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

    # Each refusal names the Nix system, and the manifest's downloads. The
    # negative manifests are the fixture with one transformation each.
    expect_refusal() {
      local name="$1" filter="$2" system="$3" reason="$4" status=0
      "$jq" "$filter" ${fixtures}/manifest.json > "$name.json"
      ${select} "$name.json" > /dev/null 2> err.txt || status=$?
      [ "$status" != 0 ]
      grep -qF "$system" err.txt
      grep -qF "$reason" err.txt
      grep -qF 'manifest downloads:' err.txt
      grep -qF 'kirocli-x86_64-linux-musl.tar.gz' err.txt
    }
    # Wanted entry missing.
    expect_refusal missing-entry \
      '.packages |= map(select(.download != "3.1.0/kirocli-x86_64-linux.tar.gz"))' \
      x86_64-linux '0 manifest entries match'
    # Wanted entry listed twice.
    expect_refusal duplicate-entry \
      '.packages += [.packages[] | select(.download == "3.1.0/kirocli-x86_64-linux.tar.gz")]' \
      x86_64-linux '2 manifest entries match'
    # Selected download from another version than the manifest's.
    expect_refusal stale-download \
      '(.packages[] | select(.download == "3.1.0/kirocli-universal-darwin.tar.gz") | .download) = "3.0.0/kirocli-universal-darwin.tar.gz"' \
      aarch64-darwin 'is not under manifest version 3.1.0'

    # Update decision, against sources.json pins written by hand. The pin
    # equals the selection: skip. A same-version pin with one old URL must
    # update; a decision on version alone would skip it. A pin at another
    # version with equal URLs must update; a decision on URLs alone would skip
    # it.
    pin() {
      "$jq" -n --arg v "$1" --arg l "$2" --arg d "$3" '{
        version: $v,
        "x86_64-linux": {url: $l, hash: "sha256-x"},
        "aarch64-darwin": {url: $d, hash: "sha256-y"}
      }' > "$4"
    }
    base=https://desktop-release.q.us-east-1.amazonaws.com
    pin 3.1.0 $base/3.1.0/kirocli-x86_64-linux.tar.gz $base/3.1.0/kirocli-universal-darwin.tar.gz same.json
    [ "$(${decide} selected.json same.json)" = skip ]
    pin 3.1.0 $base/3.1.0/kirocli-x86_64-linux-old.tar.gz $base/3.1.0/kirocli-universal-darwin.tar.gz renamed.json
    [ "$(${decide} selected.json renamed.json)" = update ]
    pin 3.0.0 $base/3.1.0/kirocli-x86_64-linux.tar.gz $base/3.1.0/kirocli-universal-darwin.tar.gz bumped.json
    [ "$(${decide} selected.json bumped.json)" = update ]

    touch "$out"
  '';
}

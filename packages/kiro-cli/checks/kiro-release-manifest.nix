# The fixture keeps a Darwin ZIP, a Linux tar.zst, and a musl tarball as
# alternatives to the selected tarballs. Expected URLs are written by hand
# from the manifest's download paths.
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

    # The Linux musl tarball shares the selected archive's file type, and
    # the tar.zst shares its target triple. Neither field alone is enough.
    ${select} ${fixtures}/manifest.json > selected.json
    base=https://desktop-release.q.us-east-1.amazonaws.com
    darwin="$base/3.1.0/kirocli-universal-darwin.tar.gz"
    linux="$base/3.1.0/kirocli-x86_64-linux.tar.gz"
    "$jq" -e --arg darwin "$darwin" --arg linux "$linux" '. == {
      version: "3.1.0", urls: {"aarch64-darwin": $darwin, "x86_64-linux": $linux}
    }' selected.json > /dev/null

    # Each refusal names the Nix system, the reason, and the manifest's downloads. The
    # negative manifests are the fixture with one transformation each.
    expect_refusal() {
      local name="$1" filter="$2" system="$3" reason="$4" status=0
      "$jq" "$filter" ${fixtures}/manifest.json > "$name.json"
      ${select} "$name.json" > /dev/null 2> err.txt || status=$?
      [ "$status" != 0 ]
      grep -qF "$system" err.txt
      grep -qF "$reason" err.txt
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
        "aarch64-darwin": {hash: "sha256-y", url: $d},
        "x86_64-linux": {hash: "sha256-x", url: $l}
      }' > "$4"
    }
    expect_decision() {
      local regression="$1" expected="$2" version="$3" linux_url="$4" observed
      pin "$version" "$linux_url" "$darwin" pin.json
      observed="$(${decide} selected.json pin.json)"
      if [ "$observed" != "$expected" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$regression" "$expected" "$observed" >&2
        return 1
      fi
    }
    expect_decision 'equal version and URLs do not trigger an update' skip 3.1.0 "$linux"
    expect_decision 'a changed URL triggers a same-version update' update 3.1.0 "$base/3.1.0/kirocli-x86_64-linux-old.tar.gz"
    expect_decision 'a changed version triggers an update even at equal URLs' update 3.0.0 "$linux"

    touch "$out"
  '';
}

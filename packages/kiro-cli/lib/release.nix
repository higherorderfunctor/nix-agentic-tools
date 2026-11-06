# The Kiro release manifest as the source of the pinned release's download
# URLs: which manifest entry each Nix system takes, and the updater that writes
# those entries' URLs into sources.json.
let
  manifestUrl = "https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json";
  # `download` in the manifest is relative to this base.
  releaseBase = "https://desktop-release.q.us-east-1.amazonaws.com";
in rec {
  # Manifest entry per Nix system, by exact field values. targetTriple is what
  # tells the glibc build from the musl tarball, which share os, architecture,
  # variant and fileType. This table is the only list of supported systems: the
  # package's `meta.platforms` and `passthru.extracted` read its names.
  selectors = {
    "aarch64-darwin" = {
      fileType = "tarGz";
      targetTriple = "universal-apple-darwin";
    };
    "x86_64-linux" = {
      fileType = "tarGz";
      targetTriple = "x86_64-unknown-linux-gnu";
    };
  };

  # `select-release <manifest.json>` prints {version, urls.<system>} from that
  # one document, or exits non-zero naming the system, its selector and the
  # manifest's downloads when a system matches zero or several entries, or when
  # its download path is not under the manifest's version.
  mkSelectRelease = pkgs:
    pkgs.writeShellScript "select-kiro-release" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.jq}/bin/jq -e \
        --arg base ${pkgs.lib.escapeShellArg releaseBase} \
        --argjson selectors ${pkgs.lib.escapeShellArg (builtins.toJSON selectors)} \
        ${pkgs.lib.escapeShellArg ''
        .version as $v
        | (.packages | map(.download)) as $available
        | .packages as $entries
        | reduce ($selectors | to_entries[]) as $sys ({version: $v, urls: {}};
            [$entries[] | select(. as $e | $sys.value | to_entries | all($e[.key] == .value))] as $hits
            | if ($hits | length) != 1 then
                error("kiro-cli: \($sys.key): \($hits | length) manifest entries match \($sys.value | tojson), expected 1; manifest downloads: \($available | join(", "))")
              elif ($hits[0].download | type) != "string" or ($hits[0].download | startswith($v + "/") | not) then
                error("kiro-cli: \($sys.key): download \($hits[0].download) for \($sys.value | tojson) is not under manifest version \($v); manifest downloads: \($available | join(", "))")
              else .urls[$sys.key] = $base + "/" + $hits[0].download end)
      ''} "$1"
    '';

  # passthru.updateScript: reads the manifest once, selects every system's
  # entry from that document, and, when the version moved, prefetches each URL
  # and writes version plus {url, hash} per system to sourcesFile. It is owner-
  # local because mkUpdateScript derives a URL from a version template, while
  # here the manifest names the file.
  mkUpdateScript = {
    pkgs,
    sourcesFile,
  }:
    pkgs.writeShellScript "update-kiro-cli" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      jq=${pkgs.jq}/bin/jq

      work=$(${pkgs.coreutils}/bin/mktemp -d)
      trap '${pkgs.coreutils}/bin/rm -rf "$work"' EXIT

      ${pkgs.curl}/bin/curl -fsSL ${manifestUrl} -o "$work/manifest.json"
      "${mkSelectRelease pkgs}" "$work/manifest.json" > "$work/selection.json"

      latest=$("$jq" -r '.version' "$work/selection.json")
      current=$("$jq" -r '.version' "${sourcesFile}")
      if [ "$latest" = "$current" ]; then
        echo "kiro-cli: already at $current"
        exit 0
      fi
      echo "kiro-cli: $current -> $latest"

      "$jq" -n --arg v "$latest" '{version: $v}' > "$work/sources.json"
      for system in $("$jq" -r '.urls | keys[]' "$work/selection.json"); do
        url=$("$jq" -r --arg s "$system" '.urls[$s]' "$work/selection.json")
        prefetched=$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 "$url")
        hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 "$prefetched")
        "$jq" --arg s "$system" --arg u "$url" --arg h "$hash" \
          '. + {($s): {url: $u, hash: $h}}' "$work/sources.json" > "$work/next.json"
        ${pkgs.coreutils}/bin/mv "$work/next.json" "$work/sources.json"
      done
      ${pkgs.coreutils}/bin/mv "$work/sources.json" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
    '';
}

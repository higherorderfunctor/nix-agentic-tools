{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-22";
  contentHash = "sha256-ZdC3KulFm5hFwx9df7a5vazB3i9ztagDmzNYv1TjiWM=";
  hash = "sha256-ywzY5J3vvwrHkFH8x1aLd0iIvp/DwtBiufV08cEbyeQ=";
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "kimchi-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    index = {
      url = "https://docs.kimchi.dev/llms.txt";
      allowedPaths = ["/llms.txt"];
      allowedPrefixes = ["/docs/"];
      deniedPaths = ["/login" "/logout"];
      deniedSegments = ["api-next" "cdn-cgi" "edit" "suggested-edits"];
      requiredIndexes = ["https://docs.kimchi.dev/docs/llms.txt"];
    };
    generated.ATTRIBUTION = ''
      Kimchi documentation snapshot

      Copyright the Kimchi documentation authors.
      Source: https://docs.kimchi.dev/
      Snapshot date: {snapshot_date}

      Fetched from upstream's published Markdown indexes and page endpoints. The
      documentation is not licensed by this repository; all rights remain with its
      upstream owners.
    '';
    meta = {
      description = "Pinned snapshot of the Kimchi documentation site";
      homepage = "https://docs.kimchi.dev/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  }

{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-11-16";
  contentHash = "sha256-LEmirTJp8g6i0Z/12pYOOQ94C1YrSol518w9V2kAu/c=";
  hash = "sha256-7L6XLHUb7jpP33u/6P+SebSFE6OvOi7sydK5JMRRErw=";
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "kimchi-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    index = {
      url = "https://docs.kimchi.dev/llms.txt";
      allowedPaths = ["/llms.txt"];
      allowedPrefixes = ["/docs/" "/reference/"];
      deniedPaths = ["/login" "/logout"];
      deniedSegments = ["api-next" "cdn-cgi" "edit" "suggested-edits"];
      requiredIndexes = [
        "https://docs.kimchi.dev/docs/llms.txt"
        "https://docs.kimchi.dev/reference/llms.txt"
      ];
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

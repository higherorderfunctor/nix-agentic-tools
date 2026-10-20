{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-20";
  contentHash = "sha256-scTxEFVioj2RykLpl4tstuHQF/b46MGiH8iU6xaZ1N0=";
  hash = "sha256-lPGwFwitnLR/BJHih0XyslBc/O+GfISf1kzJWn2H9EM=";
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

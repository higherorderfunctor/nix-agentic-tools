{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-30";
  contentHash = "sha256-WD18MQ7bzfzB+9cqNvS/plAxUFEhjVFbhxkmlJFw2GQ=";
  hash = "sha256-AGqCuP69kw9RiQ+rBkXRmOFoEbkQUX2Hopna5zXdyIs=";
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

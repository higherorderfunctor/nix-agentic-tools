{
  inputs,
  source,
}: let
  descriptor = tree: {
    path = tree.outPath;
    inherit (tree) narHash;
  };
  cases = ["equal" "ordinary" "unselected"];
  target = case: {
    adapter = "evalModules";
    adapterVersion = "1";
    argumentDescription = {
      hash = case;
      moduleArgumentsRef = "module:" + case;
      specialArgumentsRef = "special";
    };
    evaluation = {
      kind = "rich-result";
      reference = "evaluation";
    };
    fingerprint = {
      evaluatorVersion = "pinned-test";
      libVersion = "pinned-test";
      modelVersion = "not-requested";
      policyHash = "offline";
      sourceSnapshotHash = "admitted";
    };
    inputIdentities.project = "fixture";
    observationModes = ["metadata"];
    requests = map (facet: {
      domain = "option-metadata";
      inherit facet;
      maxBytes = 1048576;
      maxDepth = 0;
      maxMemoryMiB = 1024;
      maxNodes = 100;
      maxSeconds = 30;
      path = ["demo" "answer"];
    }) ["declarations" "definitions" "priority"];
    sourceRoots = [
      {
        logicalName = "project";
        path = toString source;
        rootContentIdentity = "admitted";
      }
      {
        logicalName = "nixpkgs";
        path = inputs.nixpkgs.outPath;
        rootContentIdentity = "admitted";
      }
      {
        logicalName = "nixql";
        path = inputs.nixql.outPath;
        rootContentIdentity = "admitted";
      }
    ];
    syntaxOnlyFallback = false;
    system = "x86_64-linux";
  };
in {
  bindings =
    builtins.listToAttrs (map (case: {
        name = "module:" + case;
        value = {
          inherit case;
          nixpkgs = descriptor inputs.nixpkgs;
          nixql = descriptor inputs.nixql;
        };
      })
      cases)
    // {
      evaluation.expression = toString source + "/projection.nix";
      special = {};
    };
  manifest = {
    manifestVersion = 1;
    targets = builtins.listToAttrs (map (case: {
        name = case;
        value = target case;
      })
      cases);
  };
}

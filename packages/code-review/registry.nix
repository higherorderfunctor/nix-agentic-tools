{facetOwner, ...}: {
  documentation.skillDescriptions.code-review = "Native Kimchi and Kiro code review with shared local evidence and durable role receipts; enable via ai.programs.code-review.enable";
  fragments.categories.code-review = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "code-review";
      }
    ];
  };
}

{repoPath, ...}: {
  documentation.genericDescriptions.otel-tui = "Terminal OpenTelemetry viewer";
  update.targets.otel-tui = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/otel-tui/package.nix)];};
}

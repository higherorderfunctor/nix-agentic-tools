{repoPath, ...}: {
  documentation.genericDescriptions.gluetun = "VPN client for multiple providers (Linux only)";
  update.targets.gluetun = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/gluetun/package.nix)];};
}

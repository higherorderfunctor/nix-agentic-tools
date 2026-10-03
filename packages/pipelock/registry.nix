{repoPath, ...}: {
  documentation.genericDescriptions.pipelock = "Agent egress firewall: forward proxy with hostname, SSRF and DLP checks";
  update.targets.pipelock = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/pipelock/package.nix)];};
}

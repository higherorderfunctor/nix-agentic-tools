# The update sweep calls the interpreter's grouped release updater.
{repoPath, ...}: {
  update.targets.python-stack.flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/python-stack/package.nix)];
}

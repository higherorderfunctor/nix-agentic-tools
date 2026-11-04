# mkSandbox owns the guest mounts; modules/git.nix trusts these same paths.
{
  seed = "/mnt/seed";
}

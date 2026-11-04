# mkSandbox owns the guest mounts; modules/git.nix trusts these same paths.
{
  objects = "/mnt/objects";
  seed = "/run/sandbox/seed";
}

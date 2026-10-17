# Package-relative root of nixpkgs' complete Codex layout. The recipe publishes
# it as passthru.codexPackage.root; mkCodex and daemonSelect share the same
# literal suffix so a disabled pin releases exactly the selection it wrote.
{
  root = ".";
}

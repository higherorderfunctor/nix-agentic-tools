{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "javascript";
  inherit packageLib pkgs repoPath;
}

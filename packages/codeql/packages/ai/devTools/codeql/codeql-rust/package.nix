{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "rust";
  inherit packageLib pkgs repoPath;
}

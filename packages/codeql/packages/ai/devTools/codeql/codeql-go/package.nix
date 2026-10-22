{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "go";
  inherit packageLib pkgs repoPath;
}

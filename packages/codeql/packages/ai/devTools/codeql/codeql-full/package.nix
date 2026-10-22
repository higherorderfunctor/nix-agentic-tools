{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "full";
  inherit packageLib pkgs repoPath;
}

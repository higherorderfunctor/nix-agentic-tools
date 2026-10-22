{
  nodejs,
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "javascript";
  inherit nodejs packageLib pkgs repoPath;
}

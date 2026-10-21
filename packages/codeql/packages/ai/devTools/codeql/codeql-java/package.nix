{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "java";
  inherit packageLib pkgs repoPath;
}

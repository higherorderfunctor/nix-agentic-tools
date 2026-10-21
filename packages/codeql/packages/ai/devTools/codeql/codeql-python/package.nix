{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "python";
  inherit packageLib pkgs repoPath;
}

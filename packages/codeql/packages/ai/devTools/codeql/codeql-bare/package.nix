{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "bare";
  inherit packageLib pkgs repoPath;
}

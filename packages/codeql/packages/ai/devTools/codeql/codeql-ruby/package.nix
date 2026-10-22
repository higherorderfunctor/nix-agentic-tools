{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "ruby";
  inherit packageLib pkgs repoPath;
}

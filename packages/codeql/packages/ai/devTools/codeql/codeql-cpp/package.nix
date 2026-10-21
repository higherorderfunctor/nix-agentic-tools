{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "cpp";
  inherit packageLib pkgs repoPath;
}

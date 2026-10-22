{
  packageLib,
  pkgs,
  repoPath,
}:
import ../../../../../lib/mkEngine.nix {
  engine = "csharp";
  inherit packageLib pkgs repoPath;
}

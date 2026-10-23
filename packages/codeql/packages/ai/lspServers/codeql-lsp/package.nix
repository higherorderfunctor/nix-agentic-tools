{
  pkgs,
  searchPath ? [],
}:
import ../../../../lib/language-server.nix {inherit pkgs searchPath;}

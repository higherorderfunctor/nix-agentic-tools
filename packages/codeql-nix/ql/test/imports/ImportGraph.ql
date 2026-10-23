import nix.Imports

from string file, int line, int column, string status, string target, string reason
where
  file in ["imports.nix", "nested/relative.nix"] and
  Imports::importSite(file, line, column, status, target, reason)
select file, line, column, status, target, reason

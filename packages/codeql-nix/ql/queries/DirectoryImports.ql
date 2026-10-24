/**
 * @name Directory and search-path imports
 * @description Target-qualified directory and search-path import candidates; no execution claims.
 * @kind table
 * @id nix/directory-imports
 */
import nix.Imports

from string target, string file, int line, int column, string kind, string status, string path, string reason
where Imports::directoryImport(target, file, line, column, kind, status, path, reason)
select target, file, line, column, kind, status, path, reason

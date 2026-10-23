/**
 * @name Static import graph
 * @description Proven builtin import sites and admitted literal-file targets.
 * @kind table
 * @id nix/import-graph
 */
import nix.Imports

from string file, int line, int column, string status, string target, string reason
where Imports::importSite(file, line, column, status, target, reason)
select file, line, column, status, target, reason

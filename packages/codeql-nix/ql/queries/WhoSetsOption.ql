/**
 * @name Which files set an option?
 * @description Retained files, declarations and literal candidates for explicitly requested options.
 * @kind table
 * @id nix/who-sets-option
 */
import nix.WhoSetsOption

from string kind, string target, string pathJson, string file, string line, string column,
  string priority, string selected, string association
where WhoSetsOption::row(kind, target, pathJson, file, line, column, priority, selected, association)
select kind, target, pathJson, file, line, column, priority, selected, association

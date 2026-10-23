/** Q0 contract; the expected rows were authored before the query implementation. */
import nix.WhoSetsOption

from string kind, string target, string path, string file, string line, string column,
  string priority, string selected, string association
where WhoSetsOption::row(kind, target, path, file, line, column, priority, selected, association)
select kind, target, path, file, line, column, priority, selected, association

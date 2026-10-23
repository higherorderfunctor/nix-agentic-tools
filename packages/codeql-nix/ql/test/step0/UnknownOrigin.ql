/** Observed selection and declaration survive absent authenticated source files. */
import nix.WhoSetsOption

from string kind, string target, string pathJson, string file, string line,
  string column, string priority, string selected, string association
where
  WhoSetsOption::row(kind, target, pathJson, file, line, column, priority, selected, association) and
  file = "unknown"
select kind, target, pathJson, file, line, column, priority, selected, association

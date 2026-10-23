import EvalTables
from string source, string path, string file, int line, int column, string moduleFile,
  int conditions, string kind
where
  evalDefinition(source, path, file, line, column, moduleFile, 1000, true,
    conditions, false, false, kind)
select path

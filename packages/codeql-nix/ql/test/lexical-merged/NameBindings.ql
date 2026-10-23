import nix.NameBindings

from string file, int line, int column, string name, string status,
  int binderLine, int binderColumn
where nameBinding(file, line, column, name, status, binderLine, binderColumn)
select file, line, column, name, status, binderLine, binderColumn

import nix.NameBindings

from Bindings::Variable use, string status, int binderLine, int binderColumn
where
  use.getRelativePath() = "siblings.nix" and use.getName() in ["b", "c", "k"] and
  nameBinding(use.getRelativePath(), use.getLocation().getStartLine(),
    use.getLocation().getStartColumn(), use.getName(), status, binderLine, binderColumn)
select use.getLocation().getStartLine(), use.getLocation().getStartColumn(), use.getName(),
  status, binderLine, binderColumn,
  count(Bindings::Binding target | use.mustResolveTo(target))

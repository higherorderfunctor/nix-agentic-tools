import nix.Bindings

from Bindings::Variable use, int binderLine, int binderColumn
where
  use.getRelativePath() = "siblings.nix" and use.getName() = "b" and
  (use.getLocation().getStartLine() in [2, 3, 20] or use.getLocation().getStartLine() >= 27) and
  (
    exists(Bindings::Binding target |
      use.mayResolveTo(target) and
      binderLine = target.getLocation().getStartLine() and
      binderColumn = target.getLocation().getStartColumn()
    )
    or
    not exists(Bindings::Binding target | use.mayResolveTo(target)) and
    binderLine = 0 and binderColumn = 0
  )
select use.getLocation().getStartLine(), use.getLocation().getStartColumn(),
  binderLine, binderColumn,
  count(Bindings::Binding target | use.mayResolveTo(target)),
  count(Bindings::Binding target | use.mustResolveTo(target))

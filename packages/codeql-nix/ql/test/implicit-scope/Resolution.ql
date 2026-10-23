import nix.Bindings

from Bindings::Variable use, int targetLine, int targetColumn
where use.getRelativePath() = "scope.nix" and use.getName() in ["x", "missing"] and
  use.getLocation().getStartLine() in [14, 15, 16, 22, 24, 25, 26, 27] and
  (exists(Bindings::Binding target | use.mayResolveTo(target) |
    targetLine = target.getLocation().getStartLine() and targetColumn = target.getLocation().getStartColumn())
   or not exists(Bindings::Binding target | use.mayResolveTo(target)) and targetLine = 0 and targetColumn = 0)
select use.getLocation().getStartLine(), use.getLocation().getStartColumn(),
  count(Bindings::Binding target | use.mayResolveTo(target)),
  count(Bindings::Binding target | use.mustResolveTo(target)), targetLine, targetColumn

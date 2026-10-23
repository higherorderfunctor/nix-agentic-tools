/** Shared rows for the installed query and independent query tests. */
import nix.Bindings

predicate nameBinding(string file, int line, int column, string name, string status,
  int binderLine, int binderColumn) {
  exists(Bindings::Variable use |
    file = use.getRelativePath() and line = use.getLocation().getStartLine() and
    column = use.getLocation().getStartColumn() and name = use.getName() and
    status = use.getResolutionStatus() and
    (exists(Bindings::Binding target |
       use.mustResolveTo(target) and binderLine = target.getLocation().getStartLine() and
       binderColumn = target.getLocation().getStartColumn())
     or not exists(Bindings::Binding target | use.mustResolveTo(target) and exists(target.getLocation())) and
        binderLine = 0 and binderColumn = 0)
  )
}

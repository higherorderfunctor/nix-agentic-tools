import nix.Bindings
module ExtensionContract {
  predicate row(int line, int column, string name, string status,
    int mayCount, int mustCount, int binderLine, int binderColumn) {
    exists(Bindings::Variable use |
      use.getRelativePath() = "provider.nix" and
      line = use.getLocation().getStartLine() and column = use.getLocation().getStartColumn() and
      name = use.getName() and status = use.getResolutionStatus() and
      status = Bindings::resolutionStatus(use) and use.getResolutionReason() = Bindings::resolutionReason(use) and
      mayCount = count(Bindings::Binding target | use.mayResolveTo(target)) and
      mustCount = count(Bindings::Binding target | use.mustResolveTo(target)) and
      not exists(Bindings::Binding target |
        use.mayResolveTo(target) and not Bindings::mayResolveTo(use, target) or
        Bindings::mayResolveTo(use, target) and not use.mayResolveTo(target) or
        use.mustResolveTo(target) and not Bindings::mustResolveTo(use, target) or
        Bindings::mustResolveTo(use, target) and not use.mustResolveTo(target) or
        use.mustResolveTo(target) and not use.mayResolveTo(target)) and
      (exists(Bindings::Binding target | use.mustResolveTo(target) |
         binderLine = target.getLocation().getStartLine() and binderColumn = target.getLocation().getStartColumn())
       or mustCount = 0 and binderLine = 0 and binderColumn = 0)
    )
  }
}

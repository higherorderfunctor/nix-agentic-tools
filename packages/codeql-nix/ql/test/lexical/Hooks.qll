/** Synthetic identities exercise extension contracts without production models. */
import nix.Bindings
module HookContract {
  abstract class FixtureBuiltinFrame extends Bindings::OutermostBuiltinFrameProvider {
    override string getRuntimeIdentity(Bindings::Variable use) {
      use.getRelativePath() in ["negative.nix", "positive.nix"] and result = "synthetic-runtime"
    }
    override string getBindingIdentity(string name) {
      name in ["builtins", "import"] and result = "test-builtin-" + name
    }
  }
  class FixtureImplicitScope extends Bindings::ImplicitScopeProvider {
    FixtureImplicitScope() { this = "implicit-scope" }
    override predicate resolve(Bindings::Variable use, string symbol, string certainty) {
      use.getName() = "builtins" and symbol = "test-fallback" and certainty = "must"
      or use.getName() = "b" and symbol = "test-extension-b" and certainty = "must"
      or use.getName() = "x" and
        (use.getLocation().getStartLine() = 4 and symbol in ["test-first", "test-second"] and certainty = "must"
         or use.getLocation().getStartLine() != 4 and symbol = "test-may" and certainty = "may")
    }
  }
  predicate row(string file, int line, int column, string name, string status,
    int mayCount, int mustCount, string targets) {
    exists(Bindings::Variable use |
      file = use.getRelativePath() and line = use.getLocation().getStartLine() and
      column = use.getLocation().getStartColumn() and name = use.getName() and
      (file = "negative.nix" and (line in [2, 3, 6] or line = 4 and name = "x") or
       file = "duplicates.nix" and line = 2 or file = "positive.nix" and line = 14) and
      status = use.getResolutionStatus() and status = Bindings::resolutionStatus(use) and
      use.getResolutionReason() = Bindings::resolutionReason(use) and
      mayCount = count(Bindings::Binding target | use.mayResolveTo(target)) and
      mustCount = count(Bindings::Binding target | use.mustResolveTo(target)) and
      not exists(Bindings::Binding target |
        use.mayResolveTo(target) and not Bindings::mayResolveTo(use, target) or
        Bindings::mayResolveTo(use, target) and not use.mayResolveTo(target) or
        use.mustResolveTo(target) and not Bindings::mustResolveTo(use, target) or
        Bindings::mustResolveTo(use, target) and not use.mustResolveTo(target) or
        use.mustResolveTo(target) and not use.mayResolveTo(target)) and
      targets = concat(Bindings::Binding target | use.mayResolveTo(target) | target.getName(), "," order by target.getName())
    )
  }
}

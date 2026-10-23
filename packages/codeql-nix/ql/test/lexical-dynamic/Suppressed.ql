import nix.Bindings

from Bindings::Variable use, Bindings::Binding candidate
where use.getRelativePath() = "valid.nix" and use.getName() = "c" and
  use.getLocation().getStartLine() in [10, 12, 23] and use.mayResolveTo(candidate)
select use.getLocation().getStartLine(), use.getLocation().getStartColumn(),
  candidate.getLocation().getStartLine(), candidate.getLocation().getStartColumn(),
  count(Bindings::Binding target | use.mayResolveTo(target)),
  count(Bindings::Binding target | use.mustResolveTo(target))

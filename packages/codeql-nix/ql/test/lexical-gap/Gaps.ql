import nix.Bindings

from Bindings::Variable use, Bindings::Binding candidate
where use.getRelativePath() = "gap.nix" and
  use.getLocation().getStartLine() <= 11 and use.getName() in ["b", "x"] and use.mayResolveTo(candidate)
select use.getLocation().getStartLine(), use.getName(), use.getResolutionStatus(),
  count(Bindings::Binding target | use.mayResolveTo(target)),
  count(Bindings::Binding target | use.mustResolveTo(target)),
  candidate.getLocation().getStartLine(), candidate.getLocation().getStartColumn()

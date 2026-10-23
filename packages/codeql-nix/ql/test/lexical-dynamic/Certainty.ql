import nix.Bindings
from Bindings::Variable use
where use.getRelativePath() = "valid.nix" and
    use.getLocation().getStartLine() in [5, 6, 14, 16, 17, 18, 22] and use.getName() = "c"
  or use.getRelativePath() = "negative.nix" and use.getName() in ["b", "c", "d"]
select use.getRelativePath(), use.getLocation().getStartLine(), use.getLocation().getStartColumn(), use.getName(),
  count(Bindings::Binding target | use.mustResolveTo(target))

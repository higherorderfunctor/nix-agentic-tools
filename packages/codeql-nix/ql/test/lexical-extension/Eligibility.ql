import SyntheticLexical
select count(Bindings::Variable use | use.getRelativePath() = "provider.nix" and use.getLocation().getStartLine() = 14),
  count(Bindings::Variable use | use.getRelativePath() = "provider.nix" and use.getLocation().getStartLine() = 15),
  count(Bindings::Variable use | use.getRelativePath() = "provider.nix" and use.getLocation().getStartLine() = 16),
  count(Bindings::Variable use | use.getRelativePath() = "provider.nix" and use.getLocation().getStartLine() = 17)

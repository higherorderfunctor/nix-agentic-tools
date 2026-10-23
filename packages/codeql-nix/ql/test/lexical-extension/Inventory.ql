import SyntheticLexical
from Bindings::Binding binding
where binding.getLocation().getFile().getRelativePath() = "provider.nix"
select binding.getName(), binding.getLocation().getStartLine(), binding.getLocation().getStartColumn()

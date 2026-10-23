import nix.Bindings
from Bindings::Binding binding
where binding.getLocation().getFile().getRelativePath() = "inventory.nix"
select binding.getName(), binding.getLocation().getStartLine(),
  binding.getLocation().getStartColumn()

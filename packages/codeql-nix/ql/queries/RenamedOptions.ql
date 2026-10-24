/**
 * @name Renamed and aliased options
 * @description Authenticated source helper calls with literal option segment paths.
 * @kind table
 * @id nix/renamed-options
 */
import nix.Modules

from Modules::RenamedOption option
select option.getTarget().getName(), option.getAnchor().getRelativePath(),
  option.getAnchor().getStartByte(), option.getAnchor().getEndByte(),
  option.getHelperKind(), option.getFromPathJson(), option.getToPathJson()

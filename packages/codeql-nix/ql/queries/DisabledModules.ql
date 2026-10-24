/**
 * @name Disabled modules
 * @description Observed module occurrences with authenticated import-tree position and disabling.
 * @kind table
 * @id nix/disabled-modules
 */
import nix.Modules

from Modules::ModuleOccurrence occurrence, string target, string contextPathJson
where target = occurrence.getTarget().getName() and
  contextPathJson = occurrence.getContextPathJson()
select target, contextPathJson, occurrence.getOccurrencePathJson(), occurrence.getModuleKey(),
  occurrence.getOrigin().getLabel(), occurrence.isDisabled()

/**
 * @name Losing definitions
 * @description Active candidate definitions proven to lose by override priority.
 * @kind table
 * @id nix/losing-definitions
 */
import nix.Modules

from Modules::DefinitionCandidate candidate, @nx_context context, string contextPathJson
where candidate.isLosing() and
  nx_options(candidate.getOption(), context, _) and nx_contexts(context, _, _, contextPathJson)
select candidate.getOption().getTarget().getName(), contextPathJson,
  candidate.getOption().getPathJson(), candidate.getOrigin().getLabel(),
  candidate.getPriorityText(), candidate.getOption().getPriorityText(),
  true as active, false as selected, candidate.getWrapperChainJson()

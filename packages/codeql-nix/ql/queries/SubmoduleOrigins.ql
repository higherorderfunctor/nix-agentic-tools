/**
 * @name Submodule retained inputs
 * @description Retained definitions of explicitly requested concrete contexts, before outer apply.
 * @kind table
 * @id nix/submodule-origins
 */
import nix.Modules

from Modules::SelectedDefinition definition, Modules::ConcreteContext context, @nx_request request,
  string optionPathJson
where request = definition.getRequest() and context = definition.getOption().getContext() and
  nx_requests(request, _, context, "option-metadata", optionPathJson, "selection", _, _, _, _, _)
select context.getTarget().getName(), context.getInstancePathJson(), optionPathJson,
  definition.getOrdinal(), definition.getOrigin().getLabel(), definition.getPriorityText(),
  definition.getStage()

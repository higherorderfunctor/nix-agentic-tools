/**
 * @name Module retained inputs
 * @description Retained definitions with witnessed override and explicit order priorities.
 * @kind table
 * @id nix/module-selection
 */
import nix.Modules

from Modules::SelectedDefinition definition, @nx_request request, @nx_context context,
  string target, string contextPathJson, string optionPathJson, string orderPriorityJson
where request = definition.getRequest() and
  nx_requests(request, _, context, "option-metadata", optionPathJson, "selection", _, _, _, _, _) and
  nx_contexts(context, _, _, contextPathJson) and
  target = definition.getOption().getTarget().getName() and
  (orderPriorityJson = "\"" + definition.getOrderPriorityText() + "\""
   or not exists(definition.getOrderPriorityText()) and orderPriorityJson = "null")
select target, contextPathJson, optionPathJson, definition.getOrdinal(),
  definition.getOrigin().getLabel(), definition.getPriorityText(), orderPriorityJson

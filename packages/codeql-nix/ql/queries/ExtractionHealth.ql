/**
 * @name Extraction health
 * @description Recorded phase, request, capability and binding outcomes, counts and bounded diagnostics.
 * @kind table
 * @id nix/extraction-health
 */
import nix.Modules
import nix.Targets

private predicate row(string kind, string target, string pathJson, string facet,
  string state, string reason, string countText
) {
  nx_phases(_, facet, state, reason) and kind = "phase" and
  target = "" and pathJson = "" and countText = ""
  or
  exists(Targets::RequestResult request |
    kind = "request" and target = request.getTarget().getName() and
    pathJson = request.getPathJson() and facet = request.getFacet() and
    state = request.getState() and reason = request.getReason() and
    countText = request.getObservedCount().toString()
  )
  or
  exists(Targets::Target selected |
    target = selected.getName() and pathJson = "" and countText = "" and
    kind = "capability" and facet = "rename-models" and
    (nx_capabilities(selected, facet, state, reason)
     or not nx_capabilities(selected, facet, _, _) and
       state = "unavailable" and reason = "rename helper model availability was not recorded"))
  or
  exists(Targets::Target selected, int bindings |
    target = selected.getName() and pathJson = "" and kind = "binding" and
    facet = "module-library-bindings" and
    bindings = count(@nx_anchor functionAnchor, @nx_anchor formalAnchor |
      exists(@nx_request request |
        nx_requests(request, selected, _, _, _, _, _, _, _, _, _) and
        Modules::authenticatedLibraryFormal(request, functionAnchor, formalAnchor))) and
    countText = bindings.toString() and
    (bindings = 0 and state = "unavailable" and reason = "no authenticated module functions"
     or bindings > 0 and state = "partial" and reason = "authenticated functions; coverage is not exhaustive"))
  or
  exists(Modules::DefinitionCandidate candidate |
    kind = "candidate" and target = candidate.getOption().getTarget().getName() and
    pathJson = candidate.getOption().getPathJson() and facet = "all-definitions" and
    state = candidate.getSelectedState() and reason = "active=" + candidate.getActiveState() and
    countText = candidate.getOrdinal().toString())
  or
  exists(Targets::Target selected |
    target = selected.getName() and nx_capabilities(selected, "all-definitions", state, reason) and
    kind = "capability" and pathJson = "" and facet = "all-definitions" and countText = "")
  or
  nx_runs(_, _, _, _, _, _) and not exists(Targets::Target selected) and
    target = "" and pathJson = "" and state = "unavailable" and reason = "no selected targets" and
    (kind = "binding" and facet = "module-library-bindings" and countText = "0"
     or kind = "capability" and facet = "rename-models" and countText = "")
  or
  exists(string message |
    nx_diagnostics(_, _, state, message) and kind = "diagnostic" and
    target = "" and pathJson = "" and facet = "" and
    (message.length() <= 4096 and reason = message or
      message.length() > 4096 and reason = message.prefix(4096)) and countText = ""
  )
}

from string kind, string target, string pathJson, string facet, string state, string reason,
  string countText
where row(kind, target, pathJson, facet, state, reason, countText)
select kind, target, pathJson, facet, state, reason, countText

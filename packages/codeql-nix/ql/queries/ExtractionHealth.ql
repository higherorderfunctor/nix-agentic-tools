/**
 * @name Extraction health
 * @description Recorded phase and request outcomes, observation counts and bounded diagnostics.
 * @kind table
 * @id nix/extraction-health
 */
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

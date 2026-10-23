/**
 * Handwritten L0 oracle: typed observation subjects determine membership.
 * Request paths and sibling definitions cannot substitute for those links.
 * Metadata never identifies the producing expression.
 */
import nix.Ast
import nix.Modules
import nix.Origin
import nix.Targets

private string priority(Modules::ObservedOption option) {
  result = option.getPriorityText()
  or not exists(option.getPriorityText()) and result = "unknown"
}

private predicate row(string kind, string a, string b, string c, string d, string e) {
  exists(Modules::ObservedOption option |
    kind = "option" and a = option.getTarget().getName() and b = option.getPathJson() and
    c = priority(option) and d = count(Modules::SelectedDefinition def | def.getOption() = option).toString() and e = ""
  )
  or exists(Modules::SelectedDefinition def |
    def.isSelected() and kind = "selected" and a = def.getOption().getTarget().getName() and
    b = def.getOption().getPathJson() and c = def.getOrdinal().toString() and
    d = def.getPriorityText() and (e = def.getRelativePath() or not exists(def.getRelativePath()) and e = "none")
  )
  or exists(Modules::SelectedDefinition def, Origin::Origin origin |
    origin = def.getOrigin() and kind = "origin" and a = origin.getLabel() and
    b = origin.getAssociationQuality(def.getOption().getTarget(), def.getOption().getPathJson()) and
    c = count(Ast::Binding binding | binding = origin.getACandidate(def.getOption().getTarget(), def.getOption().getPathJson())).toString() and
    (d = origin.getRelativePath() or not exists(origin.getRelativePath()) and d = "none") and not exists(origin.getLine()) and not exists(origin.getColumn()) and e = "unknown"
  )
  or exists(Origin::Origin origin, Targets::Target target |
    origin.getLabel() = "first" and target.getName() = "beta" and kind = "admission" and
    a = origin.getLabel() and b = target.getName() and
    c = origin.getAssociationQuality(target, "[\"demo\",\"answer\"]") and
    d = count(Ast::Binding binding | binding = origin.getACandidate(target, "[\"demo\",\"answer\"]")).toString() and e = ""
  )
  or exists(Modules::ObservedOption option, Origin::Origin origin |
    origin = option.getADeclaration() and kind = "declaration" and a = option.getTarget().getName() and
    b = option.getPathJson() and c = origin.getRelativePath() and
    d = origin.getLine().toString() and e = origin.getColumn().toString()
  )
  or exists(Targets::RequestResult request |
    kind = "request" and a = request.getTarget().getName() and b = request.getPathJson() and
    c = request.getFacet() and d = request.getState() and
    e = request.getReason() + ":" + request.getObservedCount().toString()
  )
  or exists(@nx_option option, @nx_context context, Targets::Target target |
    nx_options(option, context, b) and nx_contexts(context, target, _, _) and
    not exists(Modules::ObservedOption observed | observed = option) and
    not exists(Modules::SelectedDefinition def | nx_definitions(def, option, _, _)) and
    kind = "unknown" and a = target.getName() and c = "unknown" and d = "unknown" and e = ""
  )
}

from string kind, string a, string b, string c, string d, string e
where row(kind, a, b, c, d, e)
select kind, a, b, c, d, e

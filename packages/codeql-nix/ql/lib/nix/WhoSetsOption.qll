/** File-level retained definitions and syntax candidates; neither proves value causality. */
import nix.Ast
import nix.Modules
import nix.Origin
import nix.Targets
private import nix.internal.Evaluation
private import nix.internal.RawBridge

module WhoSetsOption {
  private predicate requested(Targets::Target target, string pathJson) {
    nx_requests(_, target, _, "option-metadata", pathJson, _, _, _, _, _, _)
  }

  /** Facets have separate option identities; join witnessed priority by target and exact path. */
  bindingset[target, pathJson]
  private string priority(Targets::Target target, string pathJson) {
    exists(Modules::ObservedOption option |
      option.getTarget() = target and option.getPathJson() = pathJson and
      result = option.getPriorityText()
    )
    or
    not exists(Modules::ObservedOption option |
      option.getTarget() = target and option.getPathJson() = pathJson and
      exists(option.getPriorityText())
    ) and result = "unknown"
  }

  bindingset[origin]
  private string file(Origin::Origin origin) {
    result = origin.getRelativePath()
    or not exists(origin.getRelativePath()) and result = "unknown"
  }

  private predicate point(Origin::Origin origin, string line, string column) {
    (line = origin.getLine().toString() or
      not exists(origin.getLine()) and line = "unknown") and
    (column = origin.getColumn().toString() or
      not exists(origin.getColumn()) and column = "unknown")
  }

  private predicate retainedCandidate(Targets::Target target, string pathJson,
    Ast::Binding binding, Origin::Origin origin
  ) {
    exists(Modules::SelectedDefinition definition |
      definition.getOption().getTarget() = target and
      definition.getOption().getPathJson() = pathJson and
      origin = definition.getOrigin() and binding = origin.getACandidate(target, pathJson)
    )
  }

  bindingset[target, pathJson, binding]
  private string association(Targets::Target target, string pathJson, Ast::Binding binding) {
    exists(Origin::Origin origin |
      retainedCandidate(target, pathJson, binding, origin) and
      result = origin.getAssociationQuality(target, pathJson)
    )
    or
    not exists(Origin::Origin origin | retainedCandidate(target, pathJson, binding, origin)) and
    result = "unknown"
  }

  /** All columns are text; missing evaluation evidence is explicitly unknown. */
  predicate row(string kind, string target, string pathJson, string file, string line,
    string column, string priorityText, string selected, string associationQuality
  ) {
    exists(Modules::SelectedDefinition definition, Targets::Target configuration,
      Origin::Origin origin |
      configuration = definition.getOption().getTarget() and
      pathJson = definition.getOption().getPathJson() and requested(configuration, pathJson) and
      target = configuration.getName() and origin = definition.getOrigin() and
      kind = "selected" and file = file(origin) and point(origin, line, column) and
      priorityText = priority(configuration, pathJson) and selected = "true" and
      associationQuality = origin.getAssociationQuality(configuration, pathJson)
    )
    or
    exists(Ast::Binding binding, Targets::Target configuration, @nx_file source,
      RawBridge::Anchor anchor |
      requested(configuration, pathJson) and target = configuration.getName() and
      nx_target_inputs(configuration, source, _) and nx_anchors(anchor, source, _, _, _, _) and
      anchor.getUniqueNode() = binding and Evaluation::pathJson(binding) = pathJson and
      kind = "candidate" and file = binding.getRelativePath() and
      line = binding.getLocation().getStartLine().toString() and
      column = binding.getLocation().getStartColumn().toString() and
      priorityText = "unknown" and selected = "unknown" and
      associationQuality = association(configuration, pathJson, binding)
    )
    or
    exists(Modules::ObservedOption option, Targets::Target configuration, Origin::Origin origin |
      configuration = option.getTarget() and pathJson = option.getPathJson() and
      requested(configuration, pathJson) and target = configuration.getName() and
      origin = option.getADeclaration() and kind = "declaration" and
      file = file(origin) and point(origin, line, column) and
      priorityText = "unknown" and selected = "unknown" and associationQuality = "unknown"
    )
  }
}

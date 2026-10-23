/** Observed metadata subjects; absent witnesses do not establish losing definitions. */
import nix.Origin
import nix.Targets
private import nix.internal.Evaluation

module Modules {
  class ObservedOption extends @nx_option {
    ObservedOption() {
      exists(@nx_observation observation |
        Evaluation::observed(observation) and nx_observation_options(observation, this)
      )
    }
    Targets::Target getTarget() {
      exists(@nx_context context | nx_options(this, context, _) and nx_contexts(context, result, _, _))
    }
    string getPathJson() { nx_options(this, _, result) }
    string getPriorityText() { nx_option_priority(this, result) }
    Origin::Origin getADeclaration() { nx_option_declarations(this, _, result) }
    string toString() { result = this.getTarget().getName() + ":" + this.getPathJson() }
  }

  /** A retained definition with its own successful observation and observed parent option. */
  class SelectedDefinition extends @nx_definition {
    SelectedDefinition() {
      exists(@nx_observation observation, ObservedOption option |
        Evaluation::observed(observation) and nx_observation_definitions(observation, this) and
        nx_definitions(this, option, _, _)
      )
    }
    ObservedOption getOption() { nx_definitions(this, result, _, _) }
    int getOrdinal() { nx_definitions(this, _, result, _) }
    Origin::Origin getOrigin() { nx_definitions(this, _, _, result) }
    string getPriorityText() { result = this.getOption().getPriorityText() }
    string getRelativePath() { result = this.getOrigin().getRelativePath() }
    predicate isSelected() { any() }
    string toString() { result = this.getOption().toString() + ":" + this.getOrdinal().toString() }
  }
}

/** Observed metadata subjects; absent witnesses do not establish losing definitions. */
import nix.Bindings
import nix.Origin
import nix.Targets
private import nix.internal.Evaluation
private import nix.internal.RawBridge
private import nix.internal.generated.Modules as ModuleModels

module Modules {
  /** A target's root or explicitly requested concrete instance; metadata is pre-apply. */
  class ModuleContext extends @nx_context {
    Targets::Target getTarget() { nx_contexts(this, result, _, _) }
    string getInstancePathJson() { nx_contexts(this, _, _, result) }
    string toString() { result = this.getTarget().getName() + ":" + this.getInstancePathJson() }
  }

  class RootContext extends ModuleContext {
    RootContext() { nx_contexts(this, _, "root", _) }
  }

  /** A request-local child; equal instance paths from separate requests stay distinct. */
  class ConcreteContext extends ModuleContext {
    ConcreteContext() { nx_contexts(this, _, "concrete-submodule", _) }
    ModuleContext getParent() { nx_context_parents(this, result, _, _, _) }
    @nx_option getParentOption() { nx_context_parents(this, _, result, _, _) }
    string getMemberKind() { nx_context_parents(this, _, _, result, _) }
    string getMemberKey() { nx_context_parents(this, _, _, _, result) }
  }

  class ObservedOption extends @nx_option {
    ObservedOption() {
      exists(@nx_observation observation |
        Evaluation::observed(observation) and nx_observation_options(observation, this)
      )
    }
    Targets::Target getTarget() {
      exists(@nx_context context | nx_options(this, context, _) and nx_contexts(context, result, _, _))
    }
    @nx_request getRequest() {
      exists(@nx_observation observation |
        Evaluation::observed(observation) and nx_observation_options(observation, this) and
        nx_observations(observation, result, _, "observed"))
    }
    ModuleContext getContext() { nx_options(this, result, _) }
    string getPathJson() { nx_options(this, _, result) }
    string getPriorityText() { nx_option_priority(this, result) }
    Origin::Origin getADeclaration() { nx_option_declarations(this, _, result) }
    string toString() { result = this.getTarget().getName() + ":" + this.getPathJson() }
  }

  /** Facet-specific root identities share witnessed priority only within one target and exact path. */
  bindingset[target, pathJson]
  string priorityText(Targets::Target target, string pathJson) {
    exists(ObservedOption option |
      option.getTarget() = target and option.getPathJson() = pathJson and
      option.getContext() instanceof RootContext and result = option.getPriorityText())
    or not exists(ObservedOption option |
      option.getTarget() = target and option.getPathJson() = pathJson and
      option.getContext() instanceof RootContext and exists(option.getPriorityText())) and
      result = "unknown"
  }

  /** A retained definition with its own successful observation and observed parent option. */
  class SelectedDefinition extends @nx_definition {
    SelectedDefinition() {
      exists(@nx_observation observation, ObservedOption option |
        Evaluation::observed(observation) and nx_observation_definitions(observation, this) and
        nx_definitions(this, option, _, _) and
        nx_observations(observation, option.getRequest(), _, "observed")
      )
    }
    @nx_request getRequest() {
      nx_observations(any(@nx_observation o | nx_observation_definitions(o, this) and
        Evaluation::observed(o)), result, _, "observed") and result = this.getOption().getRequest()
    }
    ObservedOption getOption() { nx_definitions(this, result, _, _) }
    string getOrderPriorityText() { nx_definition_order(this, result) }
    string getStage() {
      exists(@nx_observation observation |
        nx_observation_definitions(observation, this) and Evaluation::observed(observation) and
        nx_observations(observation, _, result, "observed"))
    }
    int getOrdinal() { nx_definitions(this, _, result, _) }
    Origin::Origin getOrigin() { nx_definitions(this, _, _, result) }
    string getPriorityText() { result = this.getOption().getPriorityText() }
    string getRelativePath() { result = this.getOrigin().getRelativePath() }
    predicate isSelected() { any() }
    string toString() { result = this.getOption().toString() + ":" + this.getOrdinal().toString() }
  }

  /** The adapter's invocation evidence, gated by the common generated bundle. */
  predicate authenticatedLibraryFormal(@nx_request request, RawBridge::Anchor functionAnchor,
    RawBridge::Anchor formalAnchor) {
    exists(string library, string model |
      nx_module_lib_bindings(request, functionAnchor, formalAnchor, library, model) and
      ModuleModels::libraryFingerprint(library) and ModuleModels::bundleFingerprint(model))
  }

  private predicate libraryValue(RawBridge::Node value, @nx_request request) {
    exists(RawBridge::Anchor functionAnchor, RawBridge::Anchor formalAnchor |
      authenticatedLibraryFormal(request, functionAnchor, formalAnchor) and
      value.(Bindings::Variable).mustResolveTo(Bindings::LexicalBinding(formalAnchor.getUniqueNode())))
    or exists(RawBridge::Node declaration |
      value.(Bindings::Variable).mustResolveTo(Bindings::LexicalBinding(declaration)) and
      libraryValue(RawBridge::declarationValue(declaration), request))
  }

  private predicate helper(RawBridge::Node value, string kind, string spec, string name) {
    exists(@nx_request request, string library, string model, string identity |
      libraryValue(RawBridge::selectionBase(value), request) and
      nx_module_lib_bindings(request, _, _, library, model) and
      name = RawBridge::selectedName(value) and ModuleModels::exported(name, identity) and
      ModuleModels::helper(library, model, identity, kind, spec))
    or exists(RawBridge::Node declaration |
      value.(Bindings::Variable).mustResolveTo(Bindings::LexicalBinding(declaration)) and
      helper(RawBridge::declarationValue(declaration), kind, spec, name))
  }

  private predicate propertyCall(RawBridge::Node call, RawBridge::Node callee) {
    helper(RawBridge::callee(call), _, "{\"arity\":1,\"content\":0}", _) and callee = RawBridge::callee(call)
    or helper(RawBridge::callee(RawBridge::callee(call)), _, "{\"arity\":2,\"content\":1}", _) and
      callee = RawBridge::callee(RawBridge::callee(call))
  }

  newtype PropertyIdentity = SourceProperty(RawBridge::Node node) { propertyCall(node, _) }

  /** Supported source properties; inactive source conveys no condition truth. */
  class PropertyApplication extends PropertyIdentity {
    private RawBridge::Node getNode() { this = SourceProperty(result) }
    private RawBridge::Node getHelper() { propertyCall(this.getNode(), result) }
    string getKind() { helper(this.getHelper(), result, _, _) }
    string getArgumentSpecJson() { helper(this.getHelper(), _, result, _) }
    RawBridge::Node getContent() { result = RawBridge::argument(this.getNode()) }
    RawBridge::Anchor getAnchor() { result.getUniqueNode() = this.getNode() }
    PropertyApplication getEnclosingProperty() {
      result != this and result.getContent() = RawBridge::parent*(this.getNode()) and
      not exists(PropertyApplication middle |
        middle != result and middle != this and middle.getContent() = RawBridge::parent*(this.getNode()) and
        result.getContent() = RawBridge::parent*(middle.getNode()))
    }
    RawBridge::Node getCondition() {
      this.getKind() = "if" and result = RawBridge::argument(RawBridge::callee(this.getNode()))
    }
    string getPriorityText() {
      this.getKind() in ["order", "override"] and
      (this.getArgumentSpecJson() = "{\"arity\":2,\"content\":1}" and
         result = RawBridge::integerText(RawBridge::argument(RawBridge::callee(this.getNode())))
       or this.getArgumentSpecJson() = "{\"arity\":1,\"content\":0}" and
         exists(string name | helper(this.getHelper(), _, _, name) and ModuleModels::constant(name, result)))
    }
    string toString() { result = this.getKind() + ":" + this.getAnchor().toString() }
  }

  newtype GroupIdentity = SourceGroup(PropertyApplication application, int index, RawBridge::Node content) {
    application.getKind() = "merge" and content = RawBridge::listElement(application.getContent(), index)
  }

  /** Literal mkMerge groups preserve source position and their zero-based index. */
  class PropertyGroup extends GroupIdentity {
    PropertyApplication getApplication() { this = SourceGroup(result, _, _) }
    int getIndex() { this = SourceGroup(_, result, _) }
    RawBridge::Node getContent() { this = SourceGroup(_, _, result) }
    RawBridge::Anchor getAnchor() { result.getUniqueNode() = this.getContent() }
    string toString() { result = this.getApplication().toString() + ":" + this.getIndex().toString() }
  }
}

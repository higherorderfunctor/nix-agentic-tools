// cspell:ignore newtype
/** Lexical name resolution; absent semantic evidence remains unavailable. */
import codeql.Locations
private import nix.internal.RawBridge
private import nix.internal.StaticScopes

module Bindings {
  newtype BindingIdentity =
    LexicalBinding(RawBridge::Node declaration) {
      exists(RawBridge::Node frame | declared(frame, declaration))
    } or
    BuiltinBinding(string runtimeIdentity, string symbolIdentity) {
      exists(OutermostBuiltinFrameProvider provider, Variable use |
        runtimeIdentity = provider.getRuntimeIdentity(use) and
        symbolIdentity = provider.getBindingIdentity(use.getName()))
    } or
    ExtendedBinding(string providerIdentity, string symbolIdentity) {
      exists(ImplicitScopeProvider provider, Variable use |
        providerIdentity = provider and provider.resolve(use, symbolIdentity, _))
    }

  /** A lexical declaration or an identity supplied by a semantic provider. */
  class Binding extends BindingIdentity {
    string toString() { result = this.getName() }
    string getName() {
      exists(RawBridge::Node declaration | this = LexicalBinding(declaration) |
        result = RawBridge::binderName(declaration))
      or this = BuiltinBinding(_, result)
      or this = ExtendedBinding(_, result)
    }
    Location getLocation() {
      exists(RawBridge::Node declaration | this = LexicalBinding(declaration) |
        result = declaration.getLocation())
    }
  }

  /** M3 implements this outer explicit frame; matching nonempty identities are mandatory. */
  abstract class OutermostBuiltinFrameProvider extends string {
    OutermostBuiltinFrameProvider() { this = "outermost-builtin-frame" }
    abstract string getRuntimeIdentity(Variable use);
    abstract string getModelIdentity();
    abstract string getBindingIdentity(string name);
  }

  /** N2 supplies authenticated explicit names, extra uses and per-use lookup origins. */
  abstract class LexicalScopeProvider extends string {
    LexicalScopeProvider() { this = "lexical-scope" }
    abstract predicate declaration(RawBridge::Node frame, RawBridge::Node binder);
    abstract predicate occurrence(RawBridge::Node node);
    abstract predicate excludesFrame(RawBridge::Node use, RawBridge::Node frame);
  }

  /** Implicit candidates are consulted only after all explicit frames. */
  abstract class ImplicitScopeProvider extends string {
    ImplicitScopeProvider() { this = "implicit-scope" }
    abstract predicate resolve(Variable use, string symbolIdentity, string certainty);
  }

  private predicate extended(RawBridge::Node frame, RawBridge::Node binder) {
    exists(LexicalScopeProvider provider | provider.declaration(frame, binder)) and
    exists(RawBridge::binderName(binder))
  }
  private predicate declared(RawBridge::Node frame, RawBridge::Node binder) {
    StaticScopes::binder(frame, binder) or extended(frame, binder)
  }
  private predicate contains(RawBridge::Node frame, Variable use) {
    (StaticScopes::contains(frame, use)
     or exists(LexicalScopeProvider provider |
       provider.declaration(frame, _) and frame = RawBridge::parent+(use))) and
    not exists(LexicalScopeProvider provider | provider.excludesFrame(use, frame))
  }
  private int depth(RawBridge::Node frame) {
    result = StaticScopes::depth(frame)
    or not exists(StaticScopes::depth(frame)) and
      result = count(RawBridge::Node ancestor | ancestor = RawBridge::parent+(frame))
  }
  private int pathDepth(RawBridge::Node frame) {
    result = StaticScopes::pathDepth(frame)
    or not exists(StaticScopes::pathDepth(frame)) and result = 0
  }
  private predicate eligible(RawBridge::Node frame, Variable use) {
    contains(frame, use) and
    exists(RawBridge::Node binder | declared(frame, binder) and
      RawBridge::binderName(binder) = use.getName())
  }
  private RawBridge::Node localFrame(Variable use) {
    eligible(result, use) and not exists(RawBridge::Node nearer |
      eligible(nearer, use) and (depth(nearer) > depth(result)
        or depth(nearer) = depth(result) and pathDepth(nearer) > pathDepth(result)))
  }
  private predicate invalid(Variable use) {
    exists(RawBridge::Node frame | frame = localFrame(use) |
      StaticScopes::collides(frame, use.getName())
      or exists(RawBridge::Node left, RawBridge::Node right |
        left != right and declared(frame, left) and declared(frame, right) and
        RawBridge::binderName(left) = use.getName() and RawBridge::binderName(right) = use.getName() and
        (extended(frame, left) or extended(frame, right))))
  }
  private Binding explicitBinding(Variable use) {
    exists(RawBridge::Node frame, RawBridge::Node binder |
      frame = localFrame(use) and not invalid(use) and declared(frame, binder) and
      RawBridge::binderName(binder) = use.getName() and
      not exists(RawBridge::Node earlier |
        declared(frame, earlier) and RawBridge::binderName(earlier) = use.getName() and
        RawBridge::precedes(earlier, binder)) and
      result = LexicalBinding(binder)
    )
    or
    not exists(localFrame(use)) and
    exists(OutermostBuiltinFrameProvider provider, string runtime, string identity |
      runtime = provider.getRuntimeIdentity(use) and runtime != "" and
      runtime = provider.getModelIdentity() and identity = provider.getBindingIdentity(use.getName()) and
      identity != "" and result = BuiltinBinding(runtime, identity)
    )
  }
  private predicate uncertain(Variable use) {
    exists(int boundary | boundary = StaticScopes::uncertaintyDepth(use) |
      not exists(RawBridge::Node frame | frame = localFrame(use) and depth(frame) > boundary))
  }
  private predicate candidate(Variable use, Binding target, string certainty) {
    target = explicitBinding(use) and
      (uncertain(use) and certainty = "may" or not uncertain(use) and certainty = "must")
    or not exists(localFrame(use)) and
    not exists(OutermostBuiltinFrameProvider provider |
      provider.getBindingIdentity(use.getName()) != "") and
    exists(ImplicitScopeProvider provider, string symbol, string suppliedCertainty |
      provider.resolve(use, symbol, suppliedCertainty) and suppliedCertainty in ["must", "may"] and
      target = ExtendedBinding(provider, symbol) and
      (uncertain(use) and certainty = "may" or not uncertain(use) and certainty = suppliedCertainty))
  }

  predicate mayResolveTo(Variable use, Binding target) { candidate(use, target, _) }
  predicate mustResolveTo(Variable use, Binding target) {
    candidate(use, target, "must") and not exists(Binding other |
      mayResolveTo(use, other) and other != target)
  }
  string resolutionStatus(Variable use) {
    invalid(use) and result = "invalid"
    or exists(Binding target | mustResolveTo(use, target)) and result = "resolved"
    or not invalid(use) and not exists(Binding target | mustResolveTo(use, target)) and result = "unavailable"
  }
  string resolutionReason(Variable use) {
    invalid(use) and result = "duplicate-binder"
    or exists(Binding target | mustResolveTo(use, target)) and result = "unique-binding"
    or not invalid(use) and not exists(Binding target | mustResolveTo(use, target)) and result = "insufficient-evidence"
  }
  class Variable extends RawBridge::Node {
    Variable() {
      exists(RawBridge::binderName(this)) and
      (RawBridge::variable(this) or exists(LexicalScopeProvider provider | provider.occurrence(this)))
    }
    string getName() { result = RawBridge::binderName(this) }
    predicate mayResolveTo(Binding target) { Bindings::mayResolveTo(this, target) }
    predicate mustResolveTo(Binding target) { Bindings::mustResolveTo(this, target) }
    string getResolutionStatus() { result = resolutionStatus(this) }
    string getResolutionReason() { result = resolutionReason(this) }
  }
}

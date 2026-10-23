import nix.Bindings
private import nix.internal.RawBridge

class SyntheticLexicalProvider extends Bindings::LexicalScopeProvider {
  SyntheticLexicalProvider() { this = "lexical-scope" }
  override predicate declaration(RawBridge::Node frame, RawBridge::Node binder) {
    frame.getRelativePath() = "provider.nix" and frame.getKind() = "LetExpression" and
    frame.getLocation().getStartLine() = 4 and binder.getRelativePath() = "provider.nix" and
    binder.getKind() = "Identifier" and binder.getLocation().getStartLine() in [6, 7]
  }
  override predicate occurrence(RawBridge::Node node) {
    node.getRelativePath() = "provider.nix" and
    (node.getKind() = "Identifier" and node.getLocation().getStartLine() = 13 and RawBridge::name(node) = "extra"
     or node.getKind() = "StringExpression" and (node.getLocation().getStartLine() = 14 and node.getLocation().getStartColumn() = 14 or
         node.getLocation().getStartLine() = 15 and node.getLocation().getStartColumn() = 20 or
         node.getLocation().getStartLine() = 16 and node.getLocation().getStartColumn() = 16)
     or node.getKind() = "IntegerExpression" and node.getLocation().getStartLine() = 16)
  }
  override predicate excludesFrame(RawBridge::Node use, RawBridge::Node frame) {
    use.getRelativePath() = "provider.nix" and use.getLocation().getStartLine() in [11, 15] and
    frame.getRelativePath() = "provider.nix" and frame.getKind() = "LetExpression" and
    frame.getLocation().getStartLine() = 4
  }
}
class ForbiddenImplicitFallback extends Bindings::ImplicitScopeProvider {
  ForbiddenImplicitFallback() { this = "implicit-scope" }
  override predicate resolve(Bindings::Variable use, string symbol, string certainty) {
    use.getName() = "clash" and symbol = "forbidden-implicit" and certainty = "must"
  }
}
class ForbiddenBuiltinFallback extends Bindings::OutermostBuiltinFrameProvider {
  ForbiddenBuiltinFallback() { this = "outermost-builtin-frame" }
  override string getRuntimeIdentity(Bindings::Variable use) { use.getName() = "clash" and result = "synthetic" }
  override string getModelIdentity() { result = "synthetic" }
  override string getBindingIdentity(string name) { name = "clash" and result = "forbidden-builtin" }
}

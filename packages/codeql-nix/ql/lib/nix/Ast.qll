/** Minimal syntax candidates; these relations do not establish evaluation origins. */
import codeql.Locations
private import nix.internal.RawBridge

module Ast {
  /** An authenticated node in one of the five supported syntax forms. */
  class AstNode extends RawBridge::Node {
    AstNode() {
      this.getKind() in ["AttrsetExpression", "FunctionExpression", "Identifier", "LetExpression"]
      or RawBridge::literalBinding(this)
    }
  }

  class AttrSet extends AstNode {
    AttrSet() { this.getKind() = "AttrsetExpression" }
    Binding getABinding() { result = RawBridge::binding(this) }
  }

  class Binding extends AstNode {
    Binding() { RawBridge::literalBinding(this) }
    int getLiteralSegmentCount() { result = count(int i | exists(this.getSegment(i))) }
    string getSegment(int index) { result = RawBridge::segment(this, index) }
    AstNode getValue() { result = RawBridge::value(this) }
  }

  class Identifier extends AstNode {
    Identifier() { this.getKind() = "Identifier" }
    string getName() { result = RawBridge::name(this) }
  }

  class LetExpr extends AstNode {
    LetExpr() { this.getKind() = "LetExpression" }
    Binding getABinding() { result = RawBridge::binding(this) }
    AstNode getBody() { result = RawBridge::body(this) }
  }

  class FunctionExpr extends AstNode {
    FunctionExpr() { this.getKind() = "FunctionExpression" }
    AstNode getBody() { result = RawBridge::body(this) }
    Identifier getParameter() { result = RawBridge::parameter(this) }
  }
}

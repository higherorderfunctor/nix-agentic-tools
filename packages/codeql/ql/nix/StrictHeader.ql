/**
 * Classify shell builders as ok, missing, or unknown. This follows lexical
 * bindings and string composition, not Nix evaluation or Bash execution.
 * @kind table
 */
import codeql.nix.Nix
import codeql.nix.Scope

string funcName(AstNode fn) {
  exists(Attrpath ap, int i |
    ap = fn.(SelectExpression).getAttrpath() and
    result = ap.getAttr(i).(Identifier).getValue() and
    not exists(ap.getAttr(i + 1))
  )
  or result = fn.(VariableExpression).getName().getValue()
}

AstNode boundValue(VariableExpression ref) {
  exists(Scope s, Identifier def, Binding b |
    resolvesTo(ref, s) and s.definesName(ref.getName().getValue(), def) and
    b.getAttrpath().getAttr(0) = def and result = b.getExpression()
  )
}

AstNode unwrapped(AstNode e) {
  result = e or result = unwrapped(e.(NIX::ParenthesizedExpression).getExpression())
  or result = unwrapped(boundValue(e))
}

/** A literal component, including a locally bound or interpolated prefix. */
StringFragment fragment(AstNode e) {
  result.getParent() = unwrapped(e)
  or exists(Interpolation i | i.getParent() = unwrapped(e) |
    result = fragment(i.getExpression())
  )
  or exists(NIX::BinaryExpression b | b = unwrapped(e) and b.getOperator() = "+" |
    result = fragment(b.getLeft()) or result = fragment(b.getRight())
  )
}

bindingset[e, text]
predicate contains(AstNode e, string text) { fragment(e).getValue().matches("%" + text + "%") }

predicate literal(AstNode e) {
  (unwrapped(e) instanceof NIX::IndentedStringExpression
    or unwrapped(e) instanceof NIX::StringExpression) and
  forall(Interpolation i | i.getParent() = unwrapped(e) | literal(i.getExpression()))
  or exists(NIX::BinaryExpression b | b = unwrapped(e) and b.getOperator() = "+" |
    literal(b.getLeft()) and literal(b.getRight())
  )
}

NIX::BindingSet bindings(AstNode attrs) {
  result = unwrapped(attrs).(NIX::AttrsetExpression).getChild()
  or result = unwrapped(attrs).(NIX::RecAttrsetExpression).getChild()
}

AstNode field(AstNode attrs, string name) {
  exists(Binding b |
    b.getParent() = bindings(attrs) and
    b.getAttrpath().getAttr(0).(Identifier).getValue() = name and
    not exists(b.getAttrpath().getAttr(1)) and result = b.getExpression()
  )
}

predicate shellBody(ApplyExpression call, string fn, AstNode body, AstNode options) {
  exists(ApplyExpression inner |
    inner = call.getFunction() and fn = funcName(inner.getFunction()) and
    fn = ["writeShellScript", "writeShellScriptBin"] and body = call.getArgument() and
    options = body
  )
  or fn = "writeShellApplication" and fn = funcName(call.getFunction()) and
    options = call.getArgument() and body = field(options, "text")
}

predicate strictFlags(AstNode options) {
  exists(NIX::ListExpression flags | flags = unwrapped(field(options, "bashOptions")) |
    forall(string flag | flag = ["errexit", "errtrace", "functrace", "nounset", "pipefail"] |
      exists(int i | fragment(flags.getElement(i)).getValue() = flag)
    )
  )
}

predicate inheritsFlags(AstNode options) {
  exists(NIX::InheritedAttrs attrs, int i |
    attrs.getAttr(i).(Identifier).getValue() = "bashOptions" and
    (attrs.getParent().(NIX::InheritFrom).getParent() =
      bindings(options) or
      attrs.getParent().(NIX::Inherit).getParent() =
      bindings(options))
  )
}

predicate flagsKnown(AstNode options) {
  not exists(field(options, "bashOptions")) and not inheritsFlags(options)
  or exists(NIX::ListExpression flags | flags = unwrapped(field(options, "bashOptions")) |
    forall(int i | exists(flags.getElement(i)) | literal(flags.getElement(i)))
  )
}

from ApplyExpression call, string fn, AstNode body, AstNode options, string verdict
where
  shellBody(call, fn, body, options) and
  (
    contains(body, "shopt -s inherit_errexit") and
    (fn = "writeShellApplication" and strictFlags(options) or
      fn != "writeShellApplication" and contains(body, "set -euETo pipefail")) and
    verdict = "ok"
    or
    not (contains(body, "shopt -s inherit_errexit") and
      (fn = "writeShellApplication" and strictFlags(options) or
        fn != "writeShellApplication" and contains(body, "set -euETo pipefail"))) and
    (literal(body) and (fn != "writeShellApplication" or flagsKnown(options)) and verdict = "missing"
      or (not literal(body) or fn = "writeShellApplication" and not flagsKnown(options)) and verdict = "unknown")
  )
select verdict, fn, call.getLocation().getFile().getRelativePath() as file,
  call.getLocation().getStartLine() as line

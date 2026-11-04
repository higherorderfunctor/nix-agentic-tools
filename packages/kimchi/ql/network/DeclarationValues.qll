/** Literal declaration values for resource ids and the region registry. */
import javascript

/** Follow the binding, including a named ES import, never a same-name fallback. */
LexicalName resolvedBinding(VarAccess use) {
  result = use.getVariable()
  or
  exists(ImportSpecifier spec, ES2015Module module_ |
    spec.getLocal().getVariable() = use.getVariable() and
    module_ = spec.getImportDeclaration().getImportedModule() and
    module_.exportsAs(result, spec.getImportedName())
  )
}

string literalString(Expr value) {
  result = value.getUnderlyingValue().(StringLiteral).getValue()
  or
  exists(VariableDeclarator decl |
    decl.getBindingPattern().(VarDecl).getVariable() = resolvedBinding(value.getUnderlyingValue()) and
    decl.getDeclStmt() instanceof ConstDeclStmt and
    result = literalString(decl.getInit())
  )
}

Expr exportedInitializer(string file, string name) {
  exists(VariableDeclarator decl, ES2015Module module_ |
    module_.getFile().getRelativePath() = "kimchi/" + file and
    module_.exportsAs(decl.getBindingPattern().(VarDecl).getVariable(), name) and
    result = decl.getInit().getUnderlyingValue()
  )
}

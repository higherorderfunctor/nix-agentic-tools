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

bindingset[file]
Expr exportedInitializer(string file, string name) {
  exists(VariableDeclarator decl, ES2015Module module_ |
    module_.getFile().getRelativePath() = "kimchi/" + file and
    module_.exportsAs(decl.getBindingPattern().(VarDecl).getVariable(), name) and
    result = decl.getInit().getUnderlyingValue()
  )
}

/** Immutable binding aliases only; no property, parameter or return-value flow. */
Expr boundValue(Expr value) {
  result = value.getUnderlyingValue()
  or
  exists(VariableDeclarator decl |
    decl.getBindingPattern().(VarDecl).getVariable() = resolvedBinding(value.getUnderlyingValue()) and
    decl.getDeclStmt() instanceof ConstDeclStmt and
    not decl.getBindingPattern().(VarDecl).getVariable().getAnAccess().isLValue() and
    result = boundValue(decl.getInit())
  )
}

/** Functions by declaration binding, or a method on a syntactically resolved receiver. */
Function boundFunction(Expr value) {
  result = boundValue(value).(Function)
  or
  result.(FunctionDeclStmt).getVariable() = resolvedBinding(boundValue(value))
  or
  exists(PropAccess access, ObjectExpr object |
    access = boundValue(value) and not access instanceof OptionalUse and
    object = boundValue(access.getBase()) and
    result = boundFunction(object.getPropertyByName(access.getPropertyName()).getInit())
  )
  or
  exists(PropAccess access, ClassDefinition cls |
    access = boundValue(value) and not access instanceof OptionalUse and
    (
      access.getBase() instanceof ThisExpr and
      access.getEnclosingFunction().getThisBinder() = cls.getAMethod().getInit()
      or
      cls.getIdentifier().(VarDecl).getVariable() =
        resolvedBinding(boundValue(boundValue(access.getBase()).(NewExpr).getCallee()))
    ) and
    result = cls.getMethod(access.getPropertyName()).getInit()
  )
}

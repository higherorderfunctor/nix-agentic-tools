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
  result = boundValue(value).(StringLiteral).getValue()
}

private Expr constInitializer(LexicalName binding) {
  exists(VariableDeclarator decl |
    decl.getBindingPattern().(VarDecl).getVariable() = binding and
    decl.getDeclStmt() instanceof ConstDeclStmt and
    result = decl.getInit()
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
  result = boundValue(constInitializer(resolvedBinding(value.getUnderlyingValue())))
}

/** Namespace members and const destructuring of awaited literal module imports. */
private Function importedFunction(Expr value) {
  exists(Import imp, string name, LexicalName binding |
    (
      exists(PropAccess access, ImportNamespaceSpecifier spec |
        value = access and not access instanceof OptionalUse and
        spec.getLocal().getVariable() = resolvedBinding(boundValue(access.getBase())) and
        imp = spec.getImportDeclaration() and name = access.getPropertyName()
      )
      or
      exists(VariableDeclarator decl, PropertyPattern property |
        decl.getDeclStmt() instanceof ConstDeclStmt and
        property = decl.getBindingPattern().(ObjectPattern).getAPropertyPattern() and
        property.getValuePattern().(VarDecl).getVariable() = value.(VarAccess).getVariable() and
        imp = decl.getInit().getUnderlyingValue().(AwaitExpr).getOperand().getUnderlyingValue().(DynamicImportExpr) and
        imp.getImportedPathExpr() instanceof StringLiteral and name = property.getName()
      )
    ) and
    imp.getImportedModule().(ES2015Module).exportsAs(binding, name) and
    (result.(FunctionDeclStmt).getVariable() = binding or result = boundFunction(constInitializer(binding)))
  )
}

/** Source class declarations, including named imports and immutable aliases. */
ClassDefinition boundClass(Expr value) {
  result.getIdentifier().getVariable() = resolvedBinding(boundValue(value))
}

/** Functions by declaration binding, or a method on a syntactically resolved receiver. */
Function boundFunction(Expr value) {
  result = boundValue(value).(Function)
  or
  result.(FunctionDeclStmt).getVariable() = resolvedBinding(boundValue(value))
  or
  result = importedFunction(boundValue(value))
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
      cls = boundClass(boundValue(access.getBase()).(NewExpr).getCallee())
    ) and
    result = cls.getMethod(access.getPropertyName()).getInit()
  )
}

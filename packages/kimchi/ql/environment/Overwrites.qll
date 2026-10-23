/** `consumerOverridable: false`: the variables `kimchi/src/entry.ts` assigns on every launch before anything reads them, so a value the caller sets is never read. entry.ts exists to set pi's environment before pi loads; its top-level statements run in order once the modules it statically imports have been evaluated. */

import EnvReads

TopLevel entry() { result.getFile().getRelativePath() = "kimchi/src/entry.ts" }

/** `process.env` spelled out, the only spelling that establishes an overwrite: the other spellings of the process object are recognized for reads, and counting their writes would let a read through a spelling not yet recognized pair with a counted write. */
predicate isSpelledProcessEnv(PropAccess pa) {
  pa = envObject().asExpr() and
  pa.getPropertyName() = "env" and
  pa.getBase().(VarAccess).getName() = "process"
}

/** The member `pa` names: its property name, or its computed key evaluated, else none. */
string memberName(PropAccess pa) {
  result = pa.getPropertyName()
  or
  not exists(pa.getPropertyName()) and result = constValue(pa.(IndexExpr).getIndex())
}

/** The name an assignment (any operator) or delete in `n` targets, else none. */
string assignedName(Expr n, PropAccess target) {
  (
    target = n.(Assignment).getLhs()
    or
    target = n.(DeleteExpr).getOperand()
  ) and
  target.getBase() = envObject().asExpr() and
  (
    result = memberName(target)
    or
    not exists(memberName(target)) and result = "<computed>"
  )
}

/** A top-level entry statement the ordered scan visits, at index `i`. */
Stmt scanned(int i) {
  result = entry().getChildStmt(i) and
  not result instanceof ImportDeclaration and
  not result instanceof FunctionDeclStmt
}

/** The statements the definite-write walk enters: the scanned ones, the children of a block it enters, and both arms of an if it enters that has an else. */
Stmt walked() {
  result = scanned(_)
  or
  result = walked().(BlockStmt).getAStmt()
  or
  exists(IfStmt ifs | ifs = walked() and exists(ifs.getElse()) |
    result = ifs.getThen() or result = ifs.getElse()
  )
}

/** Names `s` assigns on every path through it. */
string definiteWrite(Stmt s) {
  exists(AssignExpr a, PropAccess target |
    a = s.(ExprStmt).getExpr() and
    target = a.getLhs() and
    isSpelledProcessEnv(target.getBase()) and
    result = assignedName(a, target) and
    result != "<computed>"
  )
  or
  exists(IfStmt ifs | ifs = s |
    result = definiteWrite(ifs.getThen()) and result = definiteWrite(ifs.getElse())
  )
  or
  result = definiteWrite(s.(BlockStmt).getAStmt())
}

/** A plain object pattern with statically named properties and an optional rest binding. */
predicate namedPattern(ObjectPattern pattern) {
  forall(PropertyPattern property | property = pattern.getAPropertyPattern() |
    exists(property.getName()) and property.getValuePattern() instanceof VarDecl
  ) and
  (not exists(pattern.getRest()) or pattern.getRest() instanceof VarDecl)
}

/** Bindings holding a parameter's environment or a rest copy of it. */
Variable parameterVariable(Function callee, int index) {
  result = callee.getParameter(index).(SimpleParameter).getVariable()
  or
  exists(VariableDeclarator d, VarAccess init |
    init = d.getInit() and init.getVariable() = parameterVariable(callee, index) and
    (
      result = d.getBindingPattern().(VarDecl).getVariable()
      or
      exists(ObjectPattern pattern |
        pattern = d.getBindingPattern() and namedPattern(pattern) and
        result = pattern.getRest().(VarDecl).getVariable()
      )
    )
  )
}

/** A declared function receiving the environment, directly from entry or through a known helper. */
predicate handedTo(Expr arg, Function callee, int index) {
  exists(DataFlow::InvokeNode call |
    (
      arg = envObject().asExpr() and arg.getFile() = entry().getFile()
      or
      exists(Function parent, int parameter |
        handedTo(_, parent, parameter) and
        arg.(VarAccess).getVariable() = parameterVariable(parent, parameter)
      )
    ) and
    arg = call.getArgument(index).asExpr() and
    callee = call.getACallee() and
    callee instanceof FunctionDeclStmt and
    exists(callee.getBody())
  )
}

/** Names read through the parameter, its rest copies, and known helpers receiving either. */
string parameterRead(Function callee, int index) {
  exists(VarAccess use, PropAccess read |
    use.getVariable() = parameterVariable(callee, index) and
    read.getBase() = use and result = memberName(read)
  )
  or
  exists(VariableDeclarator d, ObjectPattern pattern |
    d.getInit().(VarAccess).getVariable() = parameterVariable(callee, index) and
    pattern = d.getBindingPattern() and namedPattern(pattern) and
    result = pattern.getAPropertyPattern().getName()
  )
  or
  exists(Expr arg, Function next, int parameter |
    arg.(VarAccess).getVariable() = parameterVariable(callee, index) and
    handedTo(arg, next, parameter) and result = parameterRead(next, parameter)
  )
}

/** A parameter use whose destination is fully followed by the parameter analysis. */
predicate followedParameterUse(VarAccess use) {
  handedTo(use, _, _)
  or
  exists(VariableDeclarator d |
    use = d.getInit() and
    (d.getBindingPattern() instanceof VarDecl or namedPattern(d.getBindingPattern()))
  )
}

/** Names a statement of entry.ts reads, the functions it hands process.env to included. */
string statementRead(Stmt s) {
  exists(DataFlow::Node site | listedRead(site, result) | site.getAstNode().getParent*() = s)
  or
  exists(Expr arg, Function callee, int index |
    arg.getParent*() = s and handedTo(arg, callee, index) and result = parameterRead(callee, index)
  )
}

/** Names read before the scan starts: in the function declarations of entry.ts. */
string functionRead() {
  exists(FunctionDeclStmt f | f = entry().getChildStmt(_) | result = statementRead(f))
}

predicate readUpTo(int i, string name) {
  name = functionRead() and exists(scanned(i))
  or
  exists(int j | j <= i and name = statementRead(scanned(j))) and exists(scanned(i))
}

/** Modules entry.ts statically imports, transitively: no `import type`, no `import()`. */
Module staticImport(Module from_) {
  exists(ImportDeclaration d |
    d.getTopLevel() = from_ and not d.isTypeOnly() and result = d.getImportedModule()
  )
  or
  exists(ReExportDeclaration d |
    d.getTopLevel() = from_ and not d.isTypeOnly() and result = d.getReExportedModule()
  )
}

/** A read of `name` in a module entry.ts statically imports, at `where_`. */
predicate importedRead(string name, string where_) {
  exists(Module m, DataFlow::Node site |
    m = staticImport+(entry()) and
    m != entry() and
    listedRead(site, name) and
    site.getFile() = m.getFile() and
    where_ = m.getFile().getRelativePath()
  )
}

/** A variable entry.ts fixes on every launch. */
predicate overwritten(string name) {
  exists(int i | name = definiteWrite(scanned(i)) and not readUpTo(i, name))
}

/** Post-order by end position, not control flow: await in one if arm still precedes a write in the other. */
bindingset[a, b]
predicate visitedNoEarlier(AstNode a, AstNode b) {
  exists(Location la, Location lb | la = a.getLocation() and lb = b.getLocation() |
    lb.getEndLine() > la.getEndLine()
    or
    lb.getEndLine() = la.getEndLine() and lb.getEndColumn() > la.getEndColumn()
    or
    lb.getEndLine() = la.getEndLine() and lb.getEndColumn() = la.getEndColumn() and
    a.getParent+() = b
  )
}

/** A top-level function declaration of entry.ts that can suspend. */
FunctionDeclStmt suspendingFunction() {
  result = entry().getChildStmt(_) and
  exists(Expr e | e.getParent+() = result | e instanceof AwaitExpr or e instanceof DynamicImportExpr)
}

/** A suspension point in a scanned statement: an await, an `import()`, or a reference to a suspending function. */
AstNode suspension() {
  result.getParent*() = scanned(_) and
  (
    result instanceof AwaitExpr
    or
    result instanceof DynamicImportExpr
    or
    result.(VarAccess).getVariable() = suspendingFunction().getVariable()
  )
}

/** The suspension point the walk reaches first; every assignment after it fails. */
AstNode firstSuspension() {
  result = suspension() and
  not exists(AstNode earlier | earlier = suspension() and earlier != result |
    visitedNoEarlier(earlier, result) and not visitedNoEarlier(result, earlier)
  )
}

/** Why the overwrite analysis cannot answer; the transform fails on any row. */
predicate overwriteFailure(string message, string where_) {
  // an environment assignment inside a function of entry.ts
  exists(Expr n, PropAccess t, string name |
    name = assignedName(n, t) and
    n.getFile() = entry().getFile() and
    exists(n.getEnclosingFunction()) and
    message = "src/entry.ts assigns " + name + " inside a function, which runs at a point the analysis does not follow" and
    where_ = n.getFile().getRelativePath() + ":" + n.getLocation().getStartLine()
  )
  or
  // an environment assignment after the first suspension point
  exists(Expr n, PropAccess t, string name, AstNode s |
    name = assignedName(n, t) and
    n.getParent*() = scanned(_) and
    not exists(n.getEnclosingFunction()) and
    s = firstSuspension() and
    visitedNoEarlier(s, n) and
    message =
      "src/entry.ts assigns " + name + " after it suspends at line " +
        s.getLocation().getStartLine() + ", when dynamically imported code may already have read it" and
    where_ = n.getFile().getRelativePath() + ":" + n.getLocation().getStartLine()
  )
  or
  // process.env used whole, other than handed to a declared function
  exists(Expr e |
    e = envObject().asExpr() and
    e.getFile() = entry().getFile() and
    not e = any(PropAccess pa).getBase() and
    not handedTo(e, _, _) and
    message =
      "src/entry.ts hands process.env to " + e.getParent().toString() +
        ", and the names that reads cannot be resolved" and
    where_ = e.getFile().getRelativePath() + ":" + e.getLocation().getStartLine()
  )
  or
  // a handed-to parameter used whole
  exists(Function callee, int index, SimpleParameter p, VarAccess use |
    handedTo(_, callee, index) and
    p = callee.getParameter(index) and
    use.getVariable() = parameterVariable(callee, index) and
    not use = any(PropAccess pa).getBase() and
    not followedParameterUse(use) and
    message =
      "the environment parameter " + p.getName() + " is used as a whole, so the names it reads cannot be listed" and
    where_ = use.getFile().getRelativePath() + ":" + use.getLocation().getStartLine()
  )
  or
  // a handed-to parameter's member whose name cannot be evaluated
  exists(Function callee, int index, SimpleParameter p, PropAccess pa |
    handedTo(_, callee, index) and
    p = callee.getParameter(index) and
    pa.getBase().(VarAccess).getVariable() = parameterVariable(callee, index) and
    not exists(memberName(pa)) and
    message =
      "the environment parameter " + p.getName() + " is indexed by a name that cannot be evaluated, so the names it reads cannot be listed" and
    where_ = pa.getFile().getRelativePath() + ":" + pa.getLocation().getStartLine()
  )
  or
  // a computed name in a walked process.env assignment
  exists(AssignExpr a, PropAccess target |
    a = walked().(ExprStmt).getExpr() and
    target = a.getLhs() and
    isSpelledProcessEnv(target.getBase()) and
    assignedName(a, target) = "<computed>" and
    message = "src/entry.ts assigns a computed environment name" and
    where_ = a.getFile().getRelativePath() + ":" + a.getLocation().getStartLine()
  )
  or
  // process.env handed to a parameter that is not a plain identifier
  exists(Expr arg, Function callee, int index |
    handedTo(arg, callee, index) and
    not callee.getParameter(index) instanceof SimpleParameter and
    message = "src/entry.ts hands process.env to a parameter it cannot name, so the names that reads cannot be listed" and
    where_ = arg.getFile().getRelativePath() + ":" + arg.getLocation().getStartLine()
  )
  or
  // an overwrite whose name a statically imported module also reads
  exists(string name, string imported |
    overwritten(name) and
    importedRead(name, imported) and
    message =
      "src/entry.ts assigns " + name + " before reading it, but " + imported +
        ", which it imports, reads it too; whether that read runs first is not decidable here" and
    where_ = imported
  )
}

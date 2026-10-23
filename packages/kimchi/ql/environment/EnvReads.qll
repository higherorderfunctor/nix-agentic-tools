/** Which `process.env` names Kimchi and pi read, and through what: the reads half of the `environment.variables` fact. */

import javascript

/** The runtime that reads from `f`: Kimchi's own source, or pi and its extensions. */
string runtimeOf(File f) {
  f.getRelativePath().matches("kimchi/src/%") and result = "kimchi"
  or
  f.getRelativePath().matches("kimchi/node_modules/%") and result = "pi"
}

/** pi-coding-agent's dist, the pi tree Kimchi's imports resolve to first. */
predicate inPiAgent(File f) {
  f.getRelativePath().matches("kimchi/node_modules/@earendil-works/pi-coding-agent/dist/%")
}

/** Files whose variable declarations the by-name constant fallback consults. */
predicate inDeclarationUniverse(File f) {
  f.getRelativePath().matches("kimchi/src/%") or inPiAgent(f)
}

/** The host package's `piConfig.name`, which pi's `APP_NAME` takes. */
string hostAppName() {
  exists(PackageJson p |
    p.getJsonFile().getRelativePath() = "kimchi/package.json" and
    result = p.getPropValue("piConfig").(JsonObject).getPropStringValue("name")
  )
}

/**
 * `APP_NAME = piConfigName || "<default>"` with `piConfigName` declared as
 * `<x>.piConfig?.name`: pi names two variables after the host application.
 */
predicate appNameShape(VariableDeclarator d, string defaultName) {
  exists(LogicalOrExpr choice, VarAccess left, VariableDeclarator src, PropAccess name |
    choice = d.getInit() and
    left = choice.getLeftOperand() and
    defaultName = choice.getRightOperand().(StringLiteral).getValue() and
    src.getBindingPattern().(VarDecl).getVariable() = left.getVariable() and
    name = src.getInit() and
    name.getPropertyName() = "name" and
    name.getBase().(PropAccess).getPropertyName() = "piConfig"
  )
}

predicate isAppNameDeclarator(VariableDeclarator d) {
  d.getBindingPattern().(VarDecl).getName() = "APP_NAME"
}

/** The declarators of the variable `v` reads, following an import to its export. */
VariableDeclarator declaratorOf(VarAccess v) {
  result.getBindingPattern().(VarDecl).getVariable() = v.getVariable()
  or
  exists(ImportSpecifier is, ES2015Module m, LexicalName exported |
    is.getLocal().getVariable() = v.getVariable() and
    m = is.getImportDeclaration().getImportedModule() and
    m.exportsAs(exported, is.getImportedName()) and
    result.getBindingPattern().(VarDecl).getVariable() = exported
  )
}

/** Initializers of a binding, including assignments in bundled module factories. */
Expr initializerOf(VarAccess v) {
  result = declaratorOf(v).getInit()
  or
  exists(AssignExpr assignment |
    assignment.getLhs().(VarAccess).getVariable() = v.getVariable() and
    result = assignment.getRhs().(StringLiteral)
  )
}

/** A variable with no initializer or assignment and no parameter declaration: a binding element, an uninitialized declarator or an unresolved import. */
predicate constantShaped(VarAccess v) {
  not exists(initializerOf(v)) and
  not exists(Parameter p | p.getAVariable() = v.getVariable()) and
  not exists(EnhancedForLoop loop | loop.getAnIterationVariable() = v.getVariable())
}

signature predicate fallbackSig(string name, string value);

/** The string an expression names a variable with: a literal, a template, a `.toUpperCase()` call, or an identifier followed to its constant. */
module Eval<fallbackSig/2 fallback> {
  string declaratorValue(VariableDeclarator d) {
    if isAppNameDeclarator(d)
    then
      exists(string defaultName | appNameShape(d, defaultName) |
        result = hostAppName()
        or
        not exists(hostAppName()) and result = defaultName
      )
    else result = constValue(d.getInit())
  }

  string identValue(VarAccess v) {
    result = declaratorValue(declaratorOf(v))
    or
    not exists(declaratorOf(v).getInit()) and result = constValue(initializerOf(v))
    or
    constantShaped(v) and fallback(v.getName(), result)
  }

  string templatePrefix(TemplateLiteral t, int i) {
    i = -1 and result = "" and exists(t)
    or
    exists(Expr el | el = t.getElement(i) |
      result = templatePrefix(t, i - 1) + el.(TemplateElement).getValue()
      or
      not el instanceof TemplateElement and
      result = templatePrefix(t, i - 1) + constValue(el)
    )
  }

  string constValue(Expr e) {
    result = e.(StringLiteral).getValue()
    or
    result = templatePrefix(e, e.(TemplateLiteral).getNumElement() - 1)
    or
    exists(MethodCallExpr m | m = e |
      m.getMethodName() = "toUpperCase" and
      m.getNumArgument() = 0 and
      result = constValue(m.getReceiver()).toUpperCase()
    )
    or
    result = identValue(e)
  }

  predicate valueByName(string name, string value) {
    exists(VariableDeclarator d |
      inDeclarationUniverse(d.getFile()) and
      d.getBindingPattern().(VarDecl).getName() = name and
      value = declaratorValue(d)
    )
  }
}

predicate noFallback(string name, string value) { none() and name = value }

module E0 = Eval<noFallback/2>;

predicate fallback1(string name, string value) {
  value = unique(string v | E0::valueByName(name, v))
}

module E1 = Eval<fallback1/2>;

predicate fallback2(string name, string value) {
  value = unique(string v | E1::valueByName(name, v))
}

/** The evaluator the extraction uses: two strata of by-name fallback. */
module E = Eval<fallback2/2>;

string constValue(Expr e) { result = E::constValue(e) }

/** A for-of loop binding the value read by `v`. */
ForOfStmt iterationOf(VarAccess v) { result.getAnIterationVariable() = v.getVariable() }

/** Values of literal arrays, aliases, and their for-of bindings, including tuple columns. */
Expr iterationValue(Expr e) {
  not e instanceof VarAccess and not e instanceof SeqExpr and not e instanceof ParExpr and result = e
  or
  result = iterationValue(declaratorOf(e).getInit())
  or
  e instanceof VarAccess and
  not exists(declaratorOf(e).getInit()) and not exists(iterationOf(e)) and result = e
  or
  exists(ForOfStmt loop, ArrayExpr array, Expr item |
    loop = iterationOf(e) and array = iterationValue(loop.getIterationDomain()) and
    item = array.getAnElement() and
    (
      loop.getLValue().(VarDecl).getVariable() = e.(VarAccess).getVariable() and
      result = iterationValue(item)
      or
      exists(ArrayPattern pattern, int column, ArrayExpr tuple |
        pattern = loop.getLValue() and
        pattern.getElement(column).(VarDecl).getVariable() = e.(VarAccess).getVariable() and
        tuple = iterationValue(item) and result = iterationValue(tuple.getElement(column))
      )
    )
  )
  or
  result = iterationValue(e.(SeqExpr).getLastOperand())
  or
  result = iterationValue(e.(ParExpr).getExpression())
}

/** Expressions whose definitions determine a literal iteration's values. */
Expr iterationDependency(Expr e) {
  result = declaratorOf(e).getInit()
  or
  result = iterationOf(e).getIterationDomain()
  or
  result = e.(ArrayExpr).getAnElement()
  or
  result = e.(SeqExpr).getLastOperand()
  or
  result = e.(ParExpr).getExpression()
  or
  result = e.(IndexExpr).getBase()
  or
  result = e.(LogicalOrExpr).getAnOperand()
}

/** Dense literal arrays with no spread have statically fixed element positions. */
predicate fixedArray(ArrayExpr array) {
  not array.hasOmittedElement() and not exists(array.getAnElement().(SpreadElement))
}

/** An iteration source is closed only when every traversed loop has literal array values. */
predicate closedIteration(Expr key) {
  exists(VarAccess v | v = iterationDependency*(key) | exists(iterationOf(v))) and
  exists(iterationValue(key)) and
  forall(VarAccess v | v = iterationDependency*(key) and exists(iterationOf(v)) |
    exists(iterationValue(iterationOf(v).getIterationDomain())) and
    forall(Expr domain | domain = iterationValue(iterationOf(v).getIterationDomain()) |
      fixedArray(domain)
    ) and
    (
      iterationOf(v).getLValue() instanceof VarDecl
      or
      exists(ArrayPattern pattern, int column |
        pattern = iterationOf(v).getLValue() and
        pattern.getElement(column).(VarDecl).getVariable() = v.getVariable() and
        not pattern.hasDefault(column) and
        forall(Expr item |
          item = iterationValue(iterationValue(iterationOf(v).getIterationDomain()).(ArrayExpr).getAnElement()) |
          fixedArray(item) and exists(item.(ArrayExpr).getElement(column))
        )
      )
    )
  ) and
  // Array uses are traced definitions, loop domains or literal column reads,
  // including std-env's returned tuple metadata. Other uses can let it escape.
  forall(VarAccess v, VarAccess use |
    v = iterationDependency*(key) and exists(iterationValue(v).(ArrayExpr)) and
    use.getVariable() = v.getVariable() |
    use = iterationDependency*(key)
    or
    exists(IndexExpr access |
      access.getBase() = use and exists(access.getIndex().(NumberLiteral).getIntValue()) and
      not access = any(Assignment assignment).getLhs()
    )
  ) and
  // Scalar binding reassignment also makes the set of values open.
  not exists(VarAccess v, VarAccess use |
    v = iterationDependency*(key) and use.getVariable() = v.getVariable() and
    use.isLValue()
  )
}

/** A function literal, or a known helper returning only function literals. */
predicate functionValue(Expr e) {
  e instanceof Function
  or
  exists(DataFlow::InvokeNode call, Function callee |
    call.asExpr() = e and callee = call.getACallee() and
    call.asExpr().(CallExpr).getCallee().(VarAccess).getVariable() = callee.(FunctionDeclStmt).getVariable() and
    exists(callee.getAReturnedExpr()) and
    forall(Expr returned | returned = callee.getAReturnedExpr() | returned instanceof Function)
  )
}

/** A conditional string-type guard keeps function alternatives out of the indexed read. */
predicate stringGuarded(VarAccess key) {
  exists(ConditionalExpr conditional, EqualityTest test, TypeofExpr type |
    key.getParent+() = conditional.getConsequent() and test = conditional.getCondition() and
    test.getOperator() = ["==", "==="] and
    type = test.getLeftOperand() and type.getOperand().(VarAccess).getVariable() = key.getVariable() and
    test.getRightOperand().(StringLiteral).getValue() = "string"
  )
}

/** A finite iteration whose alternatives all resolve, including guarded function alternatives. */
predicate resolvedIteration(VarAccess key) {
  closedIteration(key) and
  forall(Expr value | value = iterationValue(key) |
    exists(constValue(value)) or stringGuarded(key) and functionValue(value)
  )
}

/** A tuple column or fallback, evaluated for one row of the literal table. */
string tupleKey(Expr key, Variable binding, ArrayExpr tuple) {
  // Restrict the recursive relation to actual read keys and their table rows.
  exists(DataFlow::PropRead read, Expr root, VarAccess use |
    read = envReadSource().getAPropertyRead() and root = read.getPropertyNameExpr() and
    key.getParent*() = root and use = iterationDependency*(root) and
    exists(iterationOf(use)) and use.getVariable() = binding and tuple = iterationValue(use)
  ) and
  (
    result = constValue(key)
    or
    exists(IndexExpr access |
      access = key and access.getBase().(VarAccess).getVariable() = binding and
      exists(int column | column = access.getIndex().(NumberLiteral).getIntValue() |
        result = constValue(tuple.getElement(column))
        or
        not exists(tuple.getElement(column)) and result = ""
      )
    )
    or
    exists(LogicalOrExpr choice | choice = key |
      result = tupleKey(choice.getLeftOperand(), binding, tuple) and result != ""
      or
      tupleKey(choice.getLeftOperand(), binding, tuple) = "" and
      result = tupleKey(choice.getRightOperand(), binding, tuple)
    )
  )
}

/** std-env indexes a for-of tuple with `row[1] || row[0]`. */
string indexedIterationName(Expr key) {
  exists(VarAccess binding |
    binding = iterationDependency*(key) and exists(iterationOf(binding)) and
    closedIteration(key) and
    forall(Expr row | row = iterationValue(binding) |
      exists(tupleKey(key, binding.getVariable(), row.(ArrayExpr)))
    ) and
    result = tupleKey(key, binding.getVariable(), iterationValue(binding))
  )
}

/** Expressions evaluated to name a read, top-down from the read sites. */
predicate evaluated(Expr e) {
  e = any(DataFlow::PropRead r | r = envReadSource().getAPropertyRead()).getPropertyNameExpr()
  or
  exists(VarAccess key, DataFlow::InvokeNode call | helperKeyArgument(key, call, e))
  or
  exists(Expr p | evaluated(p) |
    e = p.(TemplateLiteral).getAnElement()
    or
    e = p.(MethodCallExpr).getReceiver()
    or
    e = initializerOf(p)
    or
    constantShaped(p) and
    exists(VariableDeclarator d |
      inDeclarationUniverse(d.getFile()) and
      d.getBindingPattern().(VarDecl).getName() = p.(VarAccess).getName() and
      e = d.getInit()
    )
  )
}

/** A by-name fallback the extraction consults that same-named constants disagree on. */
predicate ambiguousConstant(VarAccess v) {
  evaluated(v) and
  constantShaped(v) and
  strictcount(string value | E1::valueByName(v.getName(), value)) > 1
}

/** `process.env` on the process object, however spelled: the global under any of its names, `globalThis.process`, or the `process` module's default or namespace import. */
DataFlow::SourceNode envObject() { result = NodeJSLib::process().getAPropertyRead("env") }

/** The environment and known helpers' parameters receiving it, following local aliases at each call. */
DataFlow::SourceNode envReadSource() {
  result = envObject()
  or
  exists(DataFlow::InvokeNode call, Function callee, int index, SimpleParameter parameter |
    envReadSource().flowsTo(call.getArgument(index)) and
    callee = call.getACallee() and
    parameter = callee.getParameter(index) and
    not parameter.isRestParameter() and
    result = DataFlow::parameterNode(parameter)
  )
}


/** A declared environment reader's key parameter and the corresponding call argument. */
predicate helperKeyArgument(VarAccess key, DataFlow::InvokeNode call, Expr argument) {
  exists(DataFlow::PropRead read, FunctionDeclStmt callee, int index, SimpleParameter parameter |
    read = envReadSource().getAPropertyRead() and key = read.getPropertyNameExpr() and
    parameter = callee.getParameter(index) and parameter.getAVariable() = key.getVariable() and
    not parameter.isRestParameter() and callee = call.getACallee() and
    argument = call.getArgument(index).asExpr()
  )
}

/** The name the property read `r` reads: its property name, or its computed key evaluated. */
string readName(DataFlow::PropRead r) {
  not r.asExpr() = any(DeleteExpr d).getOperand() and
  (
    result = r.getPropertyName()
    or
    not exists(r.getPropertyName()) and result = constValue(r.getPropertyNameExpr())
    or
    exists(VarAccess key, DataFlow::InvokeNode call, Expr argument |
      key = r.getPropertyNameExpr() and helperKeyArgument(key, call, argument) and
      forall(DataFlow::InvokeNode other, Expr actual | helperKeyArgument(key, other, actual) |
        exists(constValue(actual))
      ) and
      result = constValue(argument)
    )
    or
    result = indexedIterationName(r.getPropertyNameExpr())
    or
    resolvedIteration(r.getPropertyNameExpr()) and
    result = constValue(iterationValue(r.getPropertyNameExpr()))
  )
}

/** A named read of the environment at `site`, and the name it reads. */
predicate envRead(DataFlow::Node site, string name) {
  exists(DataFlow::PropRead r | r = envReadSource().getAPropertyRead() | site = r and name = readName(r))
  or
  // Literal calls remain named even when other calls leave the helper open.
  exists(VarAccess key, DataFlow::InvokeNode call, Expr argument |
    helperKeyArgument(key, call, argument) and site = call and name = constValue(argument)
  )
}

/** A named environment read in a carried runtime. */
predicate listedRead(DataFlow::Node site, string name) {
  envRead(site, name) and
  exists(runtimeOf(site.getFile()))
}

/** Why the reads cannot be listed; the transform fails on any row. */
predicate readFailure(string message, string where_) {
  // a by-name constant fallback that same-named constants disagree on
  exists(VarAccess v | ambiguousConstant(v) |
    message = "constant " + v.getName() + " is ambiguous: same-named constants evaluate differently" and
    where_ = v.getFile().getRelativePath() + ":" + v.getLocation().getStartLine()
  )
  or
  exists(DataFlow::PropRead read, VarAccess key |
    read = envReadSource().getAPropertyRead() and key = read.getPropertyNameExpr() and
    exists(iterationOf(key)) and not resolvedIteration(key) and
    message = "the environment iteration key " + key.getName() + " cannot be resolved to a finite set of names" and
    where_ = key.getFile().getRelativePath() + ":" + key.getLocation().getStartLine()
  )
  or
  // pi's APP_NAME no longer takes the host's piConfig.name (a `.d.ts`
  // declares it without an initializer, which says nothing)
  exists(VariableDeclarator d |
    isAppNameDeclarator(d) and
    exists(d.getInit()) and
    inPiAgent(d.getFile()) and
    not appNameShape(d, _) and
    message = "pi APP_NAME is no longer piConfig.name || \"<default>\"" and
    where_ = d.getFile().getRelativePath() + ":" + d.getLocation().getStartLine()
  )
}

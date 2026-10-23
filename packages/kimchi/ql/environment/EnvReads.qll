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

/** A variable with no initialized declarator and no parameter declaration: a binding element, an uninitialized declarator or an unresolved import. */
predicate constantShaped(VarAccess v) {
  not exists(declaratorOf(v).getInit()) and
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
  not e instanceof VarAccess and result = e
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
}

/** Expressions whose definitions determine a literal iteration's values. */
Expr iterationDependency(Expr e) {
  result = declaratorOf(e).getInit()
  or
  result = iterationOf(e).getIterationDomain()
  or
  result = e.(ArrayExpr).getAnElement()
}

/** Dense literal arrays with no spread have statically fixed element positions. */
predicate fixedArray(ArrayExpr array) {
  not array.hasOmittedElement() and not exists(array.getAnElement().(SpreadElement))
}

/** An iteration source is closed only when every traversed loop has literal array values. */
predicate closedIteration(VarAccess key) {
  exists(iterationOf(key)) and
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
  // Every use of an array binding must be one of the definitions or loop
  // domains followed above. Other uses could mutate it or let it escape.
  forall(VarAccess v, VarAccess use |
    v = iterationDependency*(key) and exists(iterationValue(v).(ArrayExpr)) and
    use.getVariable() = v.getVariable() |
    use = iterationDependency*(key)
  ) and
  // Scalar binding reassignment also makes the set of values open.
  not exists(VarAccess v, VarAccess use |
    v = iterationDependency*(key) and use.getVariable() = v.getVariable() and
    (use = any(Assignment a).getLhs() or use = any(UpdateExpr update).getOperand() or use = any(PropAccess p | p = any(Assignment a).getLhs()).getBase())
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

/** Expressions evaluated to name a read, top-down from the read sites. */
predicate evaluated(Expr e) {
  e = any(DataFlow::PropRead r | r = envReadSource().getAPropertyRead()).getPropertyNameExpr()
  or
  exists(CallExpr c |
    c.getCallee().(Identifier).getName() = "getProviderEnvValue" and e = c.getArgument(0)
  )
  or
  exists(Expr p | evaluated(p) |
    e = p.(TemplateLiteral).getAnElement()
    or
    e = p.(MethodCallExpr).getReceiver()
    or
    e = declaratorOf(p).getInit()
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


/** The name the property read `r` reads: its property name, or its computed key evaluated. */
string readName(DataFlow::PropRead r) {
  not r.asExpr() = any(DeleteExpr d).getOperand() and
  (
    result = r.getPropertyName()
    or
    not exists(r.getPropertyName()) and result = constValue(r.getPropertyNameExpr())
    or
    resolvedIteration(r.getPropertyNameExpr()) and
    result = constValue(iterationValue(r.getPropertyNameExpr()))
  )
}

/** A named read of the environment at `site`, and the name it reads. */
predicate envRead(DataFlow::Node site, string name) {
  exists(DataFlow::PropRead r | r = envReadSource().getAPropertyRead() | site = r and name = readName(r))
  or
  // pi's provider helper reads the variable its first argument names.
  exists(CallExpr c | c = site.asExpr() |
    c.getCallee().(Identifier).getName() = "getProviderEnvValue" and
    name = constValue(c.getArgument(0))
  )
}

/** Shapes the TypeScript extractor that produced the committed fact did not read, kept out so the two agree byte for byte: `const { X } = process.env` (a property pattern), `import { env } from "node:process"` (a named import of env). */
predicate tsIncompatible(DataFlow::Node site) {
  exists(DataFlow::PropRead r | r = site |
    not r.asExpr() instanceof PropAccess
    or
    r.getBase().getALocalSource().getAstNode() instanceof ImportSpecifier
  )
}

/** A read the fact lists: a named read, in a shape the fact's producer reads. */
predicate listedRead(DataFlow::Node site, string name) {
  envRead(site, name) and
  not tsIncompatible(site) and
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
  or
  // `const { env: { X } } = process` anywhere: the environment taken apart by
  // a nested pattern, whose names the fact's producer could not list
  exists(DataFlow::PropRead r, PropertyPattern pp |
    r = envObject() and
    pp = r.getAstNode() and
    not pp.getValuePattern() instanceof VarDecl and
    exists(runtimeOf(pp.getFile())) and
    message = "takes process.env apart by destructuring, so the names it reads cannot be listed" and
    where_ = pp.getFile().getRelativePath() + ":" + pp.getLocation().getStartLine()
  )
  or
  // `.env` on a local binding named process: CodeQL would correctly ignore
  // it, but the fact's producer cannot tell what it holds and fails
  exists(PropAccess pa, VarAccess v |
    pa.getPropertyName() = "env" and
    v = pa.getBase() and
    v.getName() = "process" and
    not pa = envObject().asExpr() and
    exists(runtimeOf(pa.getFile())) and
    message = "takes env from a local binding named process, which cannot be identified as the environment" and
    where_ = pa.getFile().getRelativePath() + ":" + pa.getLocation().getStartLine()
  )
}

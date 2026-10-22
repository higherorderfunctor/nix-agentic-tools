/**
 * Which `process.env` names Kimchi and pi read, and through what: the reads
 * half of the `environment.variables` fact. Paths are relative to the source
 * root lib/codeql.nix stages (../../docs/kimchi-codeql.md):
 *
 *   kimchi/src/**                                    readBy "kimchi"
 *   kimchi/node_modules/@earendil-works/<pkg>/dist/  readBy "pi"
 */

import javascript

/** The runtime that reads from `f`: Kimchi's own source, or a pi package. */
string runtimeOf(File f) {
  f.getRelativePath().matches("kimchi/src/%") and result = "kimchi"
  or
  f.getRelativePath().matches("kimchi/node_modules/@earendil-works/%") and result = "pi"
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

/**
 * A variable with no initialized declarator and no parameter declaration: a
 * binding element, an uninitialized declarator or an unresolved import. Only
 * such a variable may take its value from a same-named constant elsewhere.
 */
predicate constantShaped(VarAccess v) {
  not exists(declaratorOf(v).getInit()) and
  not exists(Parameter p | p.getAVariable() = v.getVariable())
}

signature predicate fallbackSig(string name, string value);

/**
 * The string an expression names a variable with: a literal, a template, a
 * `.toUpperCase()` call, or an identifier followed to its constant. `+` is not
 * folded. `fallback` supplies the by-name value of a constant-shaped variable
 * from one stratum below, because `unique` cannot sit inside the recursion.
 */
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

/** Expressions evaluated to name a read, top-down from the read sites. */
predicate evaluated(Expr e) {
  e = any(DataFlow::PropRead r | r = envObject().getAPropertyRead()).getPropertyNameExpr()
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

/**
 * `process.env` on the process object, however spelled: the global under any
 * of its names, `globalThis.process`, or the `process` module's default or
 * namespace import. Local flow follows aliases, `??` and `||` fallbacks,
 * parameter defaults and `const { env } = process`.
 */
DataFlow::SourceNode envObject() { result = NodeJSLib::process().getAPropertyRead("env") }

/**
 * The name the property read `r` reads: its property name, or its computed
 * key evaluated. None for a key that cannot be evaluated, and for a delete
 * operand, which CodeQL reports as a read but is a write.
 */
string readName(DataFlow::PropRead r) {
  not r.asExpr() = any(DeleteExpr d).getOperand() and
  (
    result = r.getPropertyName()
    or
    not exists(r.getPropertyName()) and result = constValue(r.getPropertyNameExpr())
  )
}

/** A named read of the environment at `site`, and the name it reads. */
predicate envRead(DataFlow::Node site, string name) {
  exists(DataFlow::PropRead r | r = envObject().getAPropertyRead() | site = r and name = readName(r))
  or
  // pi's provider helper reads the variable its first argument names.
  exists(CallExpr c | c = site.asExpr() |
    c.getCallee().(Identifier).getName() = "getProviderEnvValue" and
    name = constValue(c.getArgument(0))
  )
}

/**
 * Shapes the TypeScript extractor that produced the committed fact did not
 * read, kept out so the two agree byte for byte:
 *   `const { X } = process.env` (a property pattern),
 *   `import { env } from "node:process"` (a named import of env).
 * Both are real reads; dropping this predicate adds their names.
 */
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

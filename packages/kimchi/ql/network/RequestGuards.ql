/**
 * @name Request guards
 * @description Necessary intraprocedural conditions on modeled network calls.
 * @kind table
 * @id nix-agentic-tools/kimchi-request-guards
 */
import javascript
import DeclarationValues
import Network

/** A phi with another source is possible flow, not necessary evidence. */
private predicate onlySource(DataFlow::Node value, DataFlow::SourceNode source) {
  source.flowsTo(value) and
  not exists(DataFlow::SourceNode other | other = value.getALocalSource() and other != source)
}

/** Binding-resolved Kimchi helpers; unrelated same-named functions do not qualify. */
private predicate helper(DataFlow::CallNode call, string file, string name) {
  exists(FunctionDeclStmt callee |
    callee.getVariable() = resolvedBinding(call.getCalleeNode().asExpr()) and callee.getName() = name and
    callee.getFile().getRelativePath() = "kimchi/" + file
  )
}

/** Named property paths on loadConfig's parsed result, with local aliases only. */
private predicate configRead(DataFlow::PropRead read, string key) {
  exists(DataFlow::CallNode call |
    helper(call, "src/config.ts", "loadConfig") and
    read.getContainer() = call.getContainer() and
    (
      onlySource(read.getBase(), call) and key = read.getPropertyName()
      or
      exists(DataFlow::PropRead base |
        onlySource(base.getBase(), call) and onlySource(read.getBase(), base) and
        key = base.getPropertyName() + "." + read.getPropertyName()
      )
    )
  )
}

private predicate guardSource(DataFlow::SourceNode source, string kind, string key) {
  exists(DataFlow::PropRead env, DataFlow::PropRead read |
    source = read and env.getPropertyName() = "env" and
    onlySource(env.getBase(), NodeJSLib::process()) and onlySource(read.getBase(), env) and
    key = read.getPropertyName() and kind = "env"
  )
  or
  configRead(source, key) and kind = "config"
  or
  helper(source, "src/resources/store.ts", "isResourceEnabled") and kind = "resource" and
  key = literalString(source.(DataFlow::CallNode).getArgument(0).asExpr())
}

from
  ClientRequest request, IfStmt branch, ConditionGuardNode guard, Expr test,
  DataFlow::SourceNode source, string kind, string key, boolean conditionOutcome,
  string outcome
where
  exists(requestLibrary(request)) and
  exists(requestTarget(request)) and
  guardSource(source, kind, key) and
  source.getContainer() = request.getContainer() and
  test.getEnclosingFunction() = request.asExpr().getEnclosingFunction() and
  guard.getTest() = test and guard.dominates(request.asExpr().getBasicBlock()) and
  onlySource(DataFlow::valueNode(test), source) and
  (
    branch.getCondition() = test and conditionOutcome = guard.getOutcome()
    or
    branch.getCondition().(LogNotExpr).getOperand() = test and
    conditionOutcome != guard.getOutcome()
  ) and
  (if guard.getOutcome() = true then outcome = "truthy" else outcome = "falsy")
select request.getFile().getRelativePath() as file, request.getLocation().getStartLine() as line,
  request.getLocation().getStartColumn() as column, requestLibrary(request) as library,
  branch.getFile().getRelativePath() as guardFile, branch.getLocation().getStartLine() as guardLine,
  branch.getLocation().getStartColumn() as guardColumn, kind, key, outcome,
  conditionOutcome.toString() as conditionOutcome, "intraprocedural" as scope,
  bundledModule(request) as bundled

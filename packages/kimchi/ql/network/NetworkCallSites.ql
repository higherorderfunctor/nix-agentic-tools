/**
 * @name Network call sites
 * @description Every modeled outbound request (fetch, node:http(s), WebSocket,
 *              axios, and any `request-forgery` models-as-data sink) with
 *              where its target comes from: a URL literal, a host literal
 *              joined after `://`, an environment variable, or, when none of
 *              those reaches it, what the target is read from. Origins are taint
 *              flow: an origin influences the target and is not proof that it
 *              is the whole of it.
 * @kind table
 * @id nix-agentic-tools/kimchi-network-call-sites
 */

import javascript
import Network

/** Holds if `node` is a URL literal (a string with a scheme). */
predicate urlLiteral(DataFlow::Node node, string value) {
  (node.asExpr() instanceof StringLiteral or node.asExpr() instanceof TemplateLiteral) and
  value = node.getStringValue() and
  value.regexpMatch("(?i)[a-z][a-z0-9+.-]*://.+")
}

/** Holds if `node` is a string literal shaped like a host name, with an optional port. */
predicate hostShaped(DataFlow::Node node, string value) {
  node.asExpr() instanceof StringLiteral and
  value = node.getStringValue() and
  value.regexpMatch("(?i)[a-z0-9-]+(\\.[a-z0-9-]+)+(:[0-9]+)?") and
  not value.regexpMatch("(?i).*\\.(c|m)?(js|ts|json|md|txt|yml|yaml|html|png|svg|sh)")
}

/** Flow of a host-shaped literal into the operand that follows a constant ending in `://`. */
module HostJoinConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node node) { hostShaped(node, _) }

  predicate isSink(DataFlow::Node node) {
    exists(DataFlow::Node joined, int i |
      node = StringConcatenation::getOperand(joined, i) and
      StringConcatenation::getOperand(joined, i - 1).getStringValue().matches("%://")
    )
  }
}

module HostJoinFlow = DataFlow::Global<HostJoinConfig>;

/**
 * Holds if `node` is a scheme-less host literal that is a request's target
 * itself (`https.request({ hostname: "h" })`), or that flows into a URL right
 * after a constant ending in `://`.
 */
predicate hostLiteral(DataFlow::Node node, string value) {
  hostShaped(node, value) and
  (node = requestTarget(_) or HostJoinFlow::flowFrom(node))
}

/** Holds if `node` reads the environment variable `name`. */
predicate envRead(DataFlow::PropRead node, string name) {
  node = NodeJSLib::process().getAPropertyRead("env").getAPropertyRead(name)
}

predicate origin(DataFlow::Node node, string kind, string value) {
  kind = "url" and urlLiteral(node, value)
  or
  kind = "host" and hostLiteral(node, value)
  or
  kind = "env" and envRead(node, value)
}

module TargetConfig implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node node) { origin(node, _, _) }

  predicate isSink(DataFlow::Node node) { node = requestTarget(_) }

  predicate isAdditionalFlowStep(DataFlow::Node pred, DataFlow::Node succ) {
    urlStep(pred, succ)
  }

  // Endpoint records such as kimchi's regionEndpoints() carry a dozen URL
  // fields; the default branch limit drops some of them.
  int fieldFlowBranchLimit() { result = 64 }
}

module TargetFlow = TaintTracking::Global<TargetConfig>;

/** Gets the esbuild `__commonJS` module key enclosing `n`, or "" outside one. */
string bundledModule(DataFlow::Node n) {
  result = min(string key | key = esbuildModuleKey(n.getContainer()) | key)
  or
  not exists(esbuildModuleKey(n.getContainer())) and result = ""
}

/**
 * URL literals that reach no modeled request: the inventory a regex scan
 * would list, kept so the fact never shrinks below it, but unattributed.
 */
query predicate unattributed(string value, string file, int line) {
  exists(DataFlow::Node node |
    urlLiteral(node, value) and
    not TargetFlow::flowFrom(node) and
    file = node.getFile().getRelativePath() and
    line = node.getLocation().getStartLine()
  )
}

/**
 * Holds if no origin reaches any target of `request`, and `kind` and `value`
 * say what a target is read from: `argument` and a parameter's name,
 * `property` and a property's name, else `dynamic` and the target's text.
 */
predicate dynamicTarget(ClientRequest request, string kind, string value) {
  not TargetFlow::flow(_, requestTarget(request)) and
  exists(DataFlow::Node target | target = requestTarget(request) |
    kind = "argument" and value = target.getALocalSource().(DataFlow::ParameterNode).getName()
    or
    kind = "property" and value = target.getALocalSource().(DataFlow::PropRead).getPropertyName()
    or
    not target.getALocalSource() instanceof DataFlow::ParameterNode and
    not exists(target.getALocalSource().(DataFlow::PropRead).getPropertyName()) and
    kind = "dynamic" and
    value = target.toString()
  )
}

from
  ClientRequest request, string library, string kind, string value, string originFile,
  int originLine
where
  library = requestLibrary(request) and
  (
    exists(DataFlow::Node source |
      TargetFlow::flow(source, requestTarget(request)) and
      origin(source, kind, value) and
      originFile = source.getFile().getRelativePath() and
      originLine = source.getLocation().getStartLine()
    )
    or
    dynamicTarget(request, kind, value) and
    originFile = request.getFile().getRelativePath() and
    originLine = request.getLocation().getStartLine()
  )
select request.getFile().getRelativePath() as file, request.getLocation().getStartLine() as line,
  library, kind, value, originFile, originLine, bundledModule(request) as bundled

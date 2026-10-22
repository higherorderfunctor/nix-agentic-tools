/**
 * Network call sites beyond the javascript library's own `ClientRequest`s:
 * a bridge from `request-forgery` models-as-data sinks, esbuild's bundled
 * module shapes, and taint steps through `URL` and dynamic table reads.
 */

import javascript
private import semmle.javascript.frameworks.data.internal.ApiGraphModels as Mad
private import semmle.javascript.frameworks.data.internal.ApiGraphModelsExtensions as MadRows

/**
 * Holds if `call` calls the esbuild helper `name`, under its own name or an
 * imported alias (`import{__require as r}from"./chunk-X.js"`).
 */
overlay[local?]
private predicate esbuildHelperCall(DataFlow::CallNode call, string name) {
  name = ["__require", "__commonJS", "__toESM"] and
  (
    call.getCalleeName() = name
    or
    exists(ImportSpecifier s |
      s.getImportedName() = name and
      call.getCalleeNode().asExpr().(VarAccess).getVariable() = s.getLocal().getVariable()
    )
  )
}

/** esbuild's `__require("x")` shim for a module it left external. */
overlay[local?]
class EsbuildRequire extends DataFlow::ModuleImportNode::Range, DataFlow::CallNode {
  string path;

  EsbuildRequire() {
    esbuildHelperCall(this, "__require") and
    path = this.getArgument(0).getStringValue()
  }

  override string getPath() { result = path }
}

/**
 * A bundled CommonJS package: `require_x()` where
 * `var require_x = __commonJS({"node_modules/<pkg>/<file>"(exports, module) {...}})`,
 * or `__toESM` of one. The package is the key's first `node_modules` segment.
 */
overlay[local?]
class EsbuildCommonJsImport extends DataFlow::ModuleImportNode::Range, DataFlow::CallNode {
  string path;

  EsbuildCommonJsImport() {
    // Syntactic only: ModuleImportNode feeds overlay[local] API-graph code.
    exists(DataFlow::CallNode wrapper, VariableDeclarator decl, string key |
      esbuildHelperCall(wrapper, "__commonJS") and
      key = wrapper.asExpr().(CallExpr).getArgument(0).(ObjectExpr).getAProperty().getName() and
      path = key.regexpCapture("(?:.*/)?node_modules/((?:@[^/]+/)?[^/]+)/.*", 1) and
      decl.getInit() = wrapper.asExpr() and
      this.getCalleeNode().asExpr().(VarAccess).getVariable() = decl.getBindingPattern().getVariable()
    )
    or
    exists(EsbuildCommonJsImport inner |
      esbuildHelperCall(this, "__toESM") and
      this.getArgument(0) = inner and
      path = inner.getPath()
    )
  }

  override string getPath() { result = path }
}

/** Gets an API node on a path that ends at the model sink `sink`. */
private API::Node modelAncestor(API::Node sink) {
  sink = ModelOutput::getASinkNode("request-forgery") and result = sink
  or
  result = modelAncestor(sink).getAPredecessor()
}

/**
 * Holds if `sink` is the node a `request-forgery` row names, and `callee` the
 * node its path names before its last `Argument` token.
 */
private predicate modeledSink(API::Node callee, API::Node sink) {
  exists(string type, Mad::AccessPath path, int n |
    MadRows::sinkModel(type, path, "request-forgery", _) and
    n = max(int i | path.getToken(i).getName() = "Argument") and
    callee = Mad::getNodeFromPath(type, path, n) and
    sink = Mad::getNodeFromPath(type, path, path.getNumToken())
  )
}

/**
 * An invocation of a modeled callee whose argument, or a member of it one or
 * two levels deep, is that row's `request-forgery` sink. Another call handed
 * the same options object (a logger) is not one. Makes every row of that kind
 * a `ClientRequest`, so a library needs only model rows.
 */
class ModeledClientRequest extends ClientRequest::Range, API::InvokeNode {
  API::Node sink;

  ModeledClientRequest() {
    exists(API::Node modeled, API::Node param |
      modeledSink(modeled, sink) and
      this = modeled.getAnInvocation() and
      param = this.getParameter(_)
    |
      sink = [param, param.getMember(_), param.getMember(_).getMember(_)]
    )
  }

  override DataFlow::Node getUrl() { result = sink.asSink() }

  override DataFlow::Node getHost() { none() }

  override DataFlow::Node getADataNode() { none() }

  /** Gets the package (or model type) a model path to this sink starts from. */
  string getModelPackage() { API::moduleImport(result) = modelAncestor(sink) }
}

private predicate isImportedPath(string p) { p = any(DataFlow::ModuleImportNode i).getPath() }

/**
 * `new C({ baseURL })` or `new C({ baseUrl })`: an SDK client built with a
 * base URL, matched by option name because a bundle inlines the SDK and its
 * package import is gone. A modeled package keeps its own row.
 */
class BaseUrlClientConstruction extends ClientRequest::Range, DataFlow::NewNode {
  DataFlow::Node url;

  BaseUrlClientConstruction() {
    url = this.getOptionArgument(0, ["baseURL", "baseUrl"]) and
    // `new this.constructor({...})` copies a client and names no class
    not this.getCalleeName() = "constructor" and
    not this instanceof ModeledClientRequest
  }

  override DataFlow::Node getUrl() { result = url }

  override DataFlow::Node getHost() { none() }

  override DataFlow::Node getADataNode() { none() }
}

/** Gets the package a model path to `r`'s sink starts from, preferring one the code imports. */
private string modelPackage(ModeledClientRequest r) {
  result = min(string p | p = r.getModelPackage() and isImportedPath(p) | p)
  or
  // a model type such as `undici.Dispatcher` when no package path exists
  not exists(string p | p = r.getModelPackage() and isImportedPath(p)) and
  result = min(r.getModelPackage())
}

/**
 * Gets the library a request uses, as the fact names it: `fetch`,
 * `node-http`, `websocket`, `axios`, `net`, `undici`, `sdk:<package>` for
 * any other modeled package, `sdk:<class>` for a client matched by its
 * base-URL option, else `other`.
 */
string requestLibrary(ClientRequest r) {
  (r instanceof ClientRequest::FetchUrlRequest or r instanceof TrackedFetchRequest) and
  result = "fetch"
  or
  r instanceof NodeJSLib::NodeJSClientRequest and result = "node-http"
  or
  r instanceof ClientWebSocket::ClientSocket and result = "websocket"
  or
  (r instanceof ClientRequest::AxiosUrlRequest or r instanceof ClientRequest::AxiosInstanceRequest) and
  result = "axios"
  or
  r instanceof ClientRequest::NetSocketRequest and result = "net"
  or
  result = "sdk:" + r.(BaseUrlClientConstruction).getCalleeName()
  or
  exists(string p | p = modelPackage(r) |
    if p = "undici" or p.matches("undici.%") then result = "undici" else result = "sdk:" + p
  )
  or
  not r instanceof ClientRequest::FetchUrlRequest and
  not r instanceof TrackedFetchRequest and
  not r instanceof NodeJSLib::NodeJSClientRequest and
  not r instanceof ClientWebSocket::ClientSocket and
  not r instanceof ClientRequest::AxiosUrlRequest and
  not r instanceof ClientRequest::AxiosInstanceRequest and
  not r instanceof ClientRequest::NetSocketRequest and
  not r instanceof BaseUrlClientConstruction and
  not exists(r.(ModeledClientRequest).getModelPackage()) and
  result = "other"
}

/** Gets a node that names where `r` connects: its URL, host, or a host-like option. */
DataFlow::Node requestTarget(ClientRequest r) {
  result = r.getUrl()
  or
  result = r.getHost()
  or
  // `https.request({ hostname, host, origin })`
  result = r.getUrl().getALocalSource().getAPropertyWrite(["host", "hostname", "origin", "href", "url"]).getRhs()
}

/** `new URL(x, base)` and reads of a URL's string forms. */
predicate urlStep(DataFlow::Node pred, DataFlow::Node succ) {
  exists(DataFlow::NewNode n | n = DataFlow::globalVarRef("URL").getAnInstantiation() |
    pred = n.getAnArgument() and succ = n
  )
  or
  exists(DataFlow::PropRead read |
    read.getPropertyName() = ["href", "origin", "host", "hostname"] and
    pred = read.getBase() and
    succ = read
  )
  or
  exists(DataFlow::MethodCallNode call |
    call.getMethodName() = ["toString", "toJSON"] and
    pred = call.getReceiver() and
    succ = call
  )
}

/**
 * A computed-key read, `REGIONS[region]`, reads every property, not only
 * array elements as the library's own read step does.
 */
overlay[local?]
class ComputedKeyRead extends DataFlow::AdditionalFlowStep {
  overlay[global]
  override predicate readStep(DataFlow::Node pred, DataFlow::ContentSet contents, DataFlow::Node succ) {
    exists(DataFlow::PropRead read |
      not exists(read.getPropertyName()) and
      pred = read.getBase() and
      succ = read and
      contents = DataFlow::ContentSet::anyProperty()
    )
  }
}

/**
 * `{ ...a, ...b, x }` aliases each spread operand, so the operands' properties
 * (an endpoint record's URL fields) stay readable on the result. The library
 * only taints the whole object.
 */
overlay[local?]
class ObjectSpreadAlias extends DataFlow::AdditionalFlowStep {
  overlay[global]
  override predicate step(DataFlow::Node pred, DataFlow::Node succ) {
    pred = succ.(DataFlow::ObjectLiteralNode).getASpreadProperty()
  }
}

/** Gets a reference to the global `fetch`, tracked through fields, parameters and returns. */
private DataFlow::SourceNode fetchRef(DataFlow::TypeTracker t) {
  t.start() and result = DataFlow::globalVarRef("fetch")
  or
  exists(DataFlow::TypeTracker t2 | result = fetchRef(t2).track(t2, t))
}

/**
 * A call of the global `fetch` that the library's `FetchUrlRequest` misses
 * because the function moved first: `this.fetch.call(undefined, url)`
 * (the bundled SDKs), or `fetchImpl(url)` with `fetch` passed in.
 */
class TrackedFetchRequest extends ClientRequest::Range {
  DataFlow::Node url;

  TrackedFetchRequest() {
    not this instanceof ClientRequest::FetchUrlRequest and
    exists(DataFlow::SourceNode f | f = fetchRef(DataFlow::TypeTracker::end()) |
      this = f.getACall() and url = this.getArgument(0)
      or
      this = f.getAMethodCall(["call", "apply"]) and url = this.getArgument(1)
    )
  }

  override DataFlow::Node getUrl() { result = url }

  override DataFlow::Node getHost() { none() }

  override DataFlow::Node getADataNode() { none() }
}

/** Gets the key of the esbuild `__commonJS` factory that encloses `c`. */
string esbuildModuleKey(StmtContainer c) {
  exists(DataFlow::CallNode wrapper, Property p |
    esbuildHelperCall(wrapper, "__commonJS") and
    p = wrapper.asExpr().(CallExpr).getArgument(0).(ObjectExpr).getAProperty() and
    c.getEnclosingContainer*() = p.getInit().(Function) and
    result = p.getName()
  )
}

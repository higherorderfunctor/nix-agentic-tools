/**
 * @name Request callers
 * @description Bounded caller and syntactic callback reachability, with stop boundaries.
 * @kind table
 * @id nix-agentic-tools/kimchi-request-callers
 */
import javascript
import DeclarationValues
import Network

private predicate owned(AstNode node) {
  node.getFile().getRelativePath().matches("kimchi/src/%")
}

/** Descend only through literal value properties, never spreads or stored objects. */
private ObjectExpr argumentObject(InvokeExpr call) {
  result = call.getAnArgument().getUnderlyingValue()
  or
  result = argumentObject(call).getAProperty().(ValueProperty).getInit().getUnderlyingValue()
}

/** A callback argument, including a named property of an inline options object. */
private predicate callback(Expr value, InvokeExpr call, string property) {
  (value instanceof Function or value instanceof VarAccess) and
  (
    value = call.getAnArgument().getUnderlyingValue() and property = ""
    or
    exists(Property p |
      p = argumentObject(call).getAProperty().(ValueProperty) and
      value = p.getInit().getUnderlyingValue() and
      (property = p.getName() or not exists(p.getName()) and property = "<computed>")
    )
  )
}

private predicate edge(Function fn, InvokeExpr call, string kind, string property) {
  owned(fn) and owned(call) and
  (
    (
      fn = boundFunction(call.getCallee())
      or
      fn = boundClass(call.(NewExpr).getCallee()).getConstructor().getInit()
    ) and kind = "caller" and property = ""
    or
    exists(Expr value |
      callback(value, call, property) and fn = boundFunction(value) and kind = "callback"
    )
  )
}

/** Registration at external callees is a stop, even inside another source function. */
private predicate follows(InvokeExpr call, string kind) {
  kind = "caller"
  or
  kind = "callback" and
  (
    exists(Function receiver | receiver = boundFunction(call.getCallee()) and owned(receiver))
    or
    call instanceof NewExpr and owned(boundClass(call.getCallee()))
  )
}

/** A function value escaping the two syntactic edge forms stops here. */
private predicate escape(Function fn, Expr value, string reason) {
  owned(value) and value = value.getUnderlyingValue() and fn = boundFunction(value) and
  not exists(InvokeExpr call | value = call.getCallee().getUnderlyingValue()) and
  not callback(value, _, _) and
  (if
    exists(VariableDeclarator decl | value = decl.getInit().getUnderlyingValue()) or
    exists(Assignment assign | value = assign.getRhs().getUnderlyingValue()) or
    exists(Property p | value = p.getInit().getUnderlyingValue()) or
    exists(MemberDeclaration member | value = member.getInit().getUnderlyingValue())
   then reason = "stored" else reason = "unresolved")
}

/** Ancestors are evaluation state only; the depth domain bounds recursion. */
private predicate reached(ClientRequest request, Function fn, int depth,
  Function a, Function b, Function c, Function d) {
  depth in [0..4] and
  (
    fn = request.asExpr().getEnclosingFunction() and depth = 0 and a = fn and b = fn and c = fn and d = fn
    or
    exists(Function oldest, InvokeExpr call, string kind, string property |
      reached(request, a, depth - 1, b, c, d, oldest) and edge(a, call, kind, property) and
      follows(call, kind) and fn = call.getEnclosingFunction() and
      not fn = [a, b, c, d, oldest]
    )
  )
}

private predicate row(ClientRequest request, AstNode fn, string kind, AstNode site,
  string property, string reason, int distance) {
  fn = request.asExpr().getEnclosingFunction() and kind = "enclosing" and site = fn and
  property = "" and reason = "" and distance = 0
  or
  not exists(request.asExpr().getEnclosingFunction()) and fn = request.asExpr() and site = fn and
  kind = "boundary" and property = "" and reason = "unreferenced" and distance = 0
  or
  exists(int depth, Function a, Function b, Function c, Function d |
    reached(request, fn, depth, a, b, c, d) and
    (
      exists(InvokeExpr call, string edgeKind |
        edge(fn, call, edgeKind, property) and
        (if call.getCallee().getUnderlyingValue() instanceof PropAccess
         then site = call.getCallee().getUnderlyingValue().(PropAccess).getPropertyNameExpr()
         else site = call) and
        (
          depth < 4 and kind = edgeKind and reason = "" and distance = depth + 1
          or
          kind = "boundary" and
          (
            depth = 4 and not reached(request, fn, [0..3], _, _, _, _) and
            reason = "depth" and distance = depth
            or
            depth < 4 and distance = depth + 1 and
            (
              follows(call, edgeKind) and
              call.getEnclosingFunction() = [fn, a, b, c, d] and reason = "recursion"
              or
              not follows(call, edgeKind) and
              reason = "registration"
              or
              follows(call, edgeKind) and not exists(call.getEnclosingFunction()) and reason = "unreferenced"
            )
          )
        )
      )
      or
      kind = "boundary" and property = "" and distance = depth and
      (
        escape(fn, site, reason)
        or
        not edge(fn, _, _, _) and not escape(fn, _, _) and site = fn and reason = "unreferenced"
      )
    )
  )
}

from ClientRequest request, AstNode fn, string kind, AstNode site, string property, string reason, int distance
where
  owned(request.asExpr()) and eligibleRequest(request) and
  row(request, fn, kind, site, property, reason, _) and
  distance = min(int d | row(request, fn, kind, site, property, reason, d) | d)
select request.getFile().getRelativePath() as file, request.getLocation().getStartLine() as line,
  request.getLocation().getStartColumn() as column, requestLibrary(request) as library,
  fn.getFile().getRelativePath() as functionFile, fn.getLocation().getStartLine() as functionLine,
  fn.getLocation().getStartColumn() as functionColumn, kind,
  site.getFile().getRelativePath() as siteFile, site.getLocation().getStartLine() as siteLine,
  site.getLocation().getStartColumn() as siteColumn, property, reason, distance

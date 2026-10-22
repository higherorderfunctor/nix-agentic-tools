import javascript

/** A call with a named callee in a file under the source root. */
class NamedCall extends CallExpr {
  NamedCall() {
    exists(this.getCalleeName()) and
    exists(this.getFile().getRelativePath())
  }
}

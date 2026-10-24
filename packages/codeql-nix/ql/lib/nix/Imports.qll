/** Proven builtin imports of admitted literal files; no evaluation claims. */
import nix.Bindings
private import nix.internal.BuiltinModels
private import nix.internal.RawBridge

module Imports {
  private predicate builtinVariable(RawBridge::Node node, string name) {
    exists(string identity |
      builtinIdentity("", name, identity) and
      node.(Bindings::Variable).mustResolveTo(Bindings::BuiltinBinding(_, identity)))
  }

  private predicate importCallee(RawBridge::Node callee) {
    builtinVariable(callee, "import")
    or exists(string identity |
      builtinVariable(RawBridge::selectionBase(callee), "builtins") and
      builtinIdentity("builtins", RawBridge::selectedName(callee), identity) and
      builtinIdentity("", "import", identity))
  }

  bindingset[prefix]
  private string parentDirectory(string prefix) {
    prefix = "/" and result = prefix
    or prefix != "/" and
      result = prefix.regexpReplaceAll("[^/]+/$", "")
  }

  private string candidatePath(StaticImportSite site, @nx_file source) {
    exists(string literal, string sourceName |
      source = site.getSourceFile() and sourceName = RawBridge::sourcePath(source) and
      literal = RawBridge::literalPath(RawBridge::argument(site)) and
      (literal.matches("/%") and result = literal
       or not literal.matches("/%") and
         result = sourceName.regexpReplaceAll("[^/]+$", "") + literal))
  }

  /** Finite component states for authenticated absolute source paths. */
  private predicate normalizedPrefix(string path, int offset, string prefix) {
    path = candidatePath(_, _) and offset = 0 and prefix = "/"
    or exists(int previous, string before, string tail, string head |
      normalizedPrefix(path, previous, before) and previous <= path.length() and
      tail = path.substring(previous, path.length()) and
      head = tail.regexpCapture("([^/]*)(/.*)?", 1) and
      offset = previous + head.length() + 1 and
      (head in ["", "."] and prefix = before
       or head = ".." and prefix = parentDirectory(before)
       or not head in ["", ".", ".."] and prefix = before + head + "/"))
  }

  private string normalized(string path) {
    exists(string folded |
      normalizedPrefix(path, path.length() + 1, folded) and
      folded != "" and folded != "/" and result = folded.substring(0, folded.length() - 1))
  }

  /** A call whose callee resolves definitely to the compatible builtin import. */
  class StaticImportSite extends RawBridge::Node {
    StaticImportSite() { importCallee(RawBridge::callee(this)) }

    /** A literal target proven by the source-qualified authenticated map. */
    @nx_file getTargetFile(@nx_file source) {
      RawBridge::targetPath(result) = normalized(candidatePath(this, source))
    }

    string getStatus(@nx_file source) {
      source = this.getSourceFile() and
      (exists(this.getTargetFile(source)) and result = "resolved"
       or not exists(this.getTargetFile(source)) and result = "unavailable")
    }
    string getReason(@nx_file source) {
      source = this.getSourceFile() and
      (exists(this.getTargetFile(source)) and result = ""
       or not exists(this.getTargetFile(source)) and
         (exists(RawBridge::literalPath(RawBridge::argument(this))) and result = "missing-input"
          or not exists(RawBridge::literalPath(RawBridge::argument(this))) and result = "dynamic-path"))
    }

    /** Target-qualified: producer directory/search answers, else literal files admitted to `target`. */
    @nx_file getTargetFile(@nx_target target, @nx_file source) {
      result = RawBridge::importPathTarget(target, source, RawBridge::argument(this))
      or not RawBridge::importPathCandidate(target, source, RawBridge::argument(this), _, _, _) and
        result = this.getTargetFile(source) and nx_target_inputs(target, source, _) and nx_target_inputs(target, result, _)
    }
    string getStatus(@nx_target target, @nx_file source) {
      RawBridge::importPathCandidate(target, source, RawBridge::argument(this), _, result, _)
      or not RawBridge::importPathCandidate(target, source, RawBridge::argument(this), _, _, _) and
        source = this.getSourceFile() and nx_target_inputs(target, source, _) and
        (if exists(this.getTargetFile(target, source)) then result = "resolved" else result = "unavailable")
    }
    string getReason(@nx_target target, @nx_file source) {
      RawBridge::importPathCandidate(target, source, RawBridge::argument(this), _, _, result)
      or not RawBridge::importPathCandidate(target, source, RawBridge::argument(this), _, _, _) and
        exists(this.getStatus(target, source)) and
        (if exists(this.getTargetFile(target, source)) then result = ""
         else if this.getReason(source) = "" then result = "missing-input" else result = this.getReason(source))
    }
  }

  predicate directoryImport(string target, string file, int line, int column, string kind, string status,
      string path, string reason) {
    exists(StaticImportSite site, @nx_target t, @nx_file source |
      RawBridge::importPathCandidate(t, source, RawBridge::argument(site), kind, _, _) and
      nx_targets(t, _, target, _, _, _, _, _, _, _) and nx_files(source, _, file, _, _) and
      line = RawBridge::callee(site).getLocation().getStartLine() and
      column = RawBridge::callee(site).getLocation().getStartColumn() and
      status = site.getStatus(t, source) and reason = site.getReason(t, source) and
      (nx_files(site.getTargetFile(t, source), _, path, _, _)
       or not exists(site.getTargetFile(t, source)) and path = ""))
  }

  predicate importSite(string file, int line, int column, string status, string target, string reason) {
    exists(StaticImportSite site, RawBridge::Node callee, @nx_file source |
      callee = RawBridge::callee(site) and source = site.getSourceFile() and
      nx_files(source, _, file, _, _) and
      line = callee.getLocation().getStartLine() and column = callee.getLocation().getStartColumn() and
      status = site.getStatus(source) and reason = site.getReason(source) and
      (nx_files(site.getTargetFile(source), _, target, _, _)
       or not exists(site.getTargetFile(source)) and target = ""))
  }
}

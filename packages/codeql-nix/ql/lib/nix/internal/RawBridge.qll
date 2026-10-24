// cspell:ignore Attrpath forall
/** Authenticated source anchors; generated class names stay behind this module. */
import codeql.Locations
private import nix.internal.generated.Ast as Generated

module RawBridge {
  bindingset[value]
  private string part(string value) {
    result = value.regexpReplaceAll("%", "%25").regexpReplaceAll("\\|", "%7C")
  }

  bindingset[value]
  private string decodePart(string value) {
    result = value.regexpReplaceAll("%7C", "|").regexpReplaceAll("%25", "%")
  }

  bindingset[value, number]
  private string sourcePart(string value, int number) {
    result = decodePart(value.regexpCapture("([^|]*)\\|([0-9]+)(\\|([^|]*))?", number))
  }

  private string fileKey(@nx_file file) {
    exists(string root, string path, string hash |
      nx_files(file, root, path, hash, _) and
      result = part(root) + "|" + part(path) + "|" + part(hash))
  }

  private string sourceEntry(@nx_file file) {
    databaseMetadata("nixql.s2.file|" + fileKey(file), result)
  }

  /** Canonical archive path from the authenticated source map, never the process cwd. */
  string sourcePath(@nx_file file) { result = sourcePart(sourceEntry(file), 1) }

  /** A producer directory/search candidate at `argument`'s anchor in `source`. */
  predicate importPathCandidate(@nx_target target, @nx_file source, Node argument, string kind, string status, string reason) {
    exists(Anchor anchor | argument = anchor.getUniqueNode() and nx_anchors(anchor, source, _, _, _, _) |
      nx_import_path_candidates(target, anchor, kind, status, reason))
  }
  @nx_file importPathTarget(@nx_target target, @nx_file source, Node argument) {
    exists(Anchor anchor | argument = anchor.getUniqueNode() and nx_anchors(anchor, source, _, _, _, _) |
      nx_import_path_targets(target, anchor, result))
  }

  /** Canonical or admitted lexical target path, retaining the authenticated identity. */
  string targetPath(@nx_file file) {
    result = sourcePath(file) or result = sourcePart(sourceEntry(file), 4)
  }

  private string rawPath(Generated::Nix::AstNode node) {
    not exists(node.getParent()) and result = "[]"
    or
    exists(string parent |
      parent = rawPath(node.getParent()) and
      (parent = "[]" and result = "[" + node.getParentIndex().toString() + "]"
       or parent != "[]" and result = parent.substring(0, parent.length() - 1) +
         "," + node.getParentIndex().toString() + "]")
    )
  }

  bindingset[kind]
  private predicate rawKind(Generated::Nix::AstNode node, string kind) {
    not node instanceof Generated::Nix::ReservedWord and
    kind = node.getAPrimaryQlClass().regexpReplaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase()
    or
    node instanceof Generated::Nix::ReservedWord and
    kind = node.(Generated::Nix::Token).getValue()
  }

  class Anchor extends @nx_anchor {
    string toString() { result = this.getRelativePath() + ":" + this.getStartByte().toString() }
    string getRelativePath() { nx_files(this.getSourceFile(), _, result, _, _) }
    private @nx_file getSourceFile() { nx_anchors(this, result, _, _, _, _) }
    int getStartByte() { nx_anchors(this, _, result, _, _, _) }
    int getEndByte() { nx_anchors(this, _, _, result, _, _) }
    string getKind() { nx_anchors(this, _, _, _, result, _) }
    string getChildPath() { nx_anchors(this, _, _, _, _, result) }

    private string getFileKey() {
      result = fileKey(this.getSourceFile())
    }

    private int getLineStart(int line) {
      exists(string entry |
        databaseMetadata("nixql.s2.line|" + this.getFileKey(), entry) and
        line = entry.regexpCapture("([0-9]+)\\|([0-9]+)", 1).toInt() and
        result = entry.regexpCapture("([0-9]+)\\|([0-9]+)", 2).toInt()
      )
    }

    bindingset[byte]
    private int getLineAt(int byte) {
      this.getLineStart(result) <= byte and
      not exists(int later | later > result and this.getLineStart(later) <= byte)
    }

    private int getEndLine() {
      this.getStartByte() = this.getEndByte() and result = this.getLineAt(this.getStartByte())
      or
      this.getStartByte() < this.getEndByte() and
      exists(int line |
        line = this.getLineAt(this.getEndByte()) and
        (this.getLineStart(line) = this.getEndByte() and result = line - 1
         or this.getLineStart(line) < this.getEndByte() and result = line)
      )
    }

    private Generated::Nix::AstNode getACandidate() {
      exists(string source, string position, Location location, int startLine |
        databaseMetadata("nixql.s2.file|" + this.getFileKey(), source) and
        this.getEndByte() <= sourcePart(source, 2).toInt() and
        databaseMetadata("nixql.s2.path|" + this.getFileKey() + "|" + part(this.getChildPath()), position) and
        location = result.getLocation() and
        location.getFile().getAbsolutePath() = sourcePart(source, 1) and
        rawPath(result) = position and
        startLine = this.getLineAt(this.getStartByte()) and
        location.getStartLine() = startLine and
        location.getStartColumn() = this.getStartByte() - this.getLineStart(startLine) + 1 and
        location.getEndLine() = this.getEndLine() and
        location.getEndColumn() = this.getEndByte() - this.getLineStart(this.getEndLine()) and
        rawKind(result, this.getKind())
      )
    }

    int getCandidateCount() {
      result = count(Generated::Nix::AstNode node | node = this.getACandidate())
    }

    string getMappingState() {
      this.getCandidateCount() = 0 and result = "unmapped"
      or this.getCandidateCount() = 1 and result = "unique"
      or this.getCandidateCount() > 1 and result = "ambiguous"
    }

    @nix_ast_node getUniqueNode() {
      this.getCandidateCount() = 1 and result = this.getACandidate()
    }

    Location getRawLocation() {
      this.getCandidateCount() = 1 and result = this.getACandidate().getLocation()
    }
  }

  /** Raw syntax with exactly one authenticated source association. */
  class Node extends @nix_ast_node {
    Node() { exists(Anchor anchor | this = anchor.getUniqueNode()) }
    string toString() { result = this.getKind() }
    string getKind() { result = this.(Generated::Nix::AstNode).getAPrimaryQlClass() }
    Location getLocation() {
      exists(Anchor anchor | this = anchor.getUniqueNode() | result = anchor.getRawLocation())
    }
    string getRelativePath() {
      exists(Anchor anchor | this = anchor.getUniqueNode() | result = anchor.getRelativePath())
    }
    @nx_file getSourceFile() {
      exists(Anchor anchor | this = anchor.getUniqueNode() |
        nx_anchors(anchor, result, _, _, _, _))
    }
  }

  private Generated::Nix::AstNode expression(Generated::Nix::AstNode node) {
    node instanceof Generated::Nix::VariableExpression and
    result = node.(Generated::Nix::VariableExpression).getName()
    or not node instanceof Generated::Nix::VariableExpression and result = node
  }

  private string literal(Generated::Nix::AstNode node) {
    result = node.(Generated::Nix::Identifier).getValue()
    or
    exists(Generated::Nix::StringExpression text |
      text = node and
      forall(Generated::Nix::AstNode child | child = text.getAChild() |
        child instanceof Generated::Nix::StringFragment
      ) and
      result = decodedString(text)
    )
  }

  predicate literalBinding(Node node) {
    exists(Anchor value |
      value.getUniqueNode() = node.(Generated::Nix::Binding).getExpression() and
      value.getStartByte() < value.getEndByte()
    ) and
    exists(Generated::Nix::Attrpath path |
      path = node.(Generated::Nix::Binding).getAttrpath() and
      exists(path.getAnAttr()) and
      forall(Generated::Nix::AstNode segment | segment = path.getAnAttr() |
        exists(literal(segment)))
    )
  }
  string segment(Node node, int index) {
    literalBinding(node) and
    result = literal(node.(Generated::Nix::Binding).getAttrpath().getAttr(index))
  }
  Node value(Node node) { result = expression(node.(Generated::Nix::Binding).getExpression()) }
  string name(Node node) { result = node.(Generated::Nix::Identifier).getValue() }
  Node body(Node node) {
    result = expression(node.(Generated::Nix::FunctionExpression).getBody())
    or result = expression(node.(Generated::Nix::LetExpression).getBody())
  }
  Node parameter(Node node) { result = node.(Generated::Nix::FunctionExpression).getUniversal() }
  Node binding(Node node) {
    result = node.(Generated::Nix::AttrsetExpression).getChild().getABinding()
    or result = node.(Generated::Nix::LetExpression).getChild().getABinding()
  }

  /** Authenticated structural edges used by meaning layers. */
  Node parent(Node node) { result = node.(Generated::Nix::AstNode).getParent() }
  predicate variable(Node node) {
    node = any(Generated::Nix::VariableExpression v).getName()
  }
  predicate precedes(Node left, Node right) {
    left.getLocation().getStartLine() < right.getLocation().getStartLine()
    or left.getLocation().getStartLine() = right.getLocation().getStartLine() and
      left.getLocation().getStartColumn() < right.getLocation().getStartColumn()
  }
  predicate setExpression(Node node) {
    node.getKind() in ["AttrsetExpression", "RecAttrsetExpression"]
  }
  private Generated::Nix::BindingSet bindingSet(Node node) {
    result = node.(Generated::Nix::AttrsetExpression).getChild()
    or result = node.(Generated::Nix::LetAttrsetExpression).getChild()
    or result = node.(Generated::Nix::LetExpression).getChild()
    or result = node.(Generated::Nix::RecAttrsetExpression).getChild()
  }
  Node container(Node node) { node = bindingSet(result).getABinding() }
  private Generated::Nix::StringExpression literalKey(Generated::Nix::AstNode node) {
    result = node.(Generated::Nix::Interpolation).getExpression() and exists(literal(result))
  }
  Node pathToken(Node node, int index) {
    exists(Generated::Nix::AstNode segment |
      segment = node.(Generated::Nix::Binding).getAttrpath().getAttr(index) and
      (result = literalKey(segment) or not exists(literalKey(segment)) and result = segment))
  }
  string binderName(Node binder) { result = literal(binder) }
  Node unparenthesized(Node node) {
    not node instanceof Generated::Nix::ParenthesizedExpression and result = node
    or result = unparenthesized(node.(Generated::Nix::ParenthesizedExpression).getExpression())
  }
  Node bindingValue(Node node) {
    result = unparenthesized(node.(Generated::Nix::Binding).getExpression())
  }
  Node inheritedToken(Node clause) {
    result = clause.(Generated::Nix::Inherit).getAttrs().getAnAttr()
    or result = clause.(Generated::Nix::InheritFrom).getAttrs().getAnAttr()
  }
  Node withEnvironment(Node frame) {
    result = unparenthesized(frame.(Generated::Nix::WithExpression).getEnvironment())
  }
  Node withBody(Node frame) { result = frame.(Generated::Nix::WithExpression).getBody() }
  predicate functionBinder(Node frame, Node binder) {
    binder = frame.(Generated::Nix::FunctionExpression).getUniversal()
    or binder = frame.(Generated::Nix::FunctionExpression).getFormals().getAFormal().getName()
  }

  /** Import-domain syntax access stays behind the authenticated bridge. */
  Node callee(Node call) {
    result = expression(unparenthesized(call.(Generated::Nix::ApplyExpression).getFunction()))
  }
  Node argument(Node call) {
    result = unparenthesized(call.(Generated::Nix::ApplyExpression).getArgument())
  }
  Node selectionBase(Node selection) {
    result = expression(unparenthesized(selection.(Generated::Nix::SelectExpression).getExpression()))
  }
  string selectedName(Node selection) {
    exists(Generated::Nix::Attrpath path |
      path = selection.(Generated::Nix::SelectExpression).getAttrpath() and
      not exists(path.getAttr(1)) and result = literal(path.getAttr(0)))
  }
  string literalPath(Node node) {
    exists(Generated::Nix::PathExpression path |
      path = node and
      forall(Generated::Nix::AstNode child | child = path.getAChild() |
        child instanceof Generated::Nix::PathFragment) and
      result = concat(int i, Generated::Nix::PathFragment fragment |
        fragment = path.getChild(i) | fragment.getValue(), "" order by i))
  }
  /** A single lexical assignment's value, for proven local helper aliases. */
  Node declarationValue(Node declaration) {
    exists(Generated::Nix::Binding binding |
      binding.getAttrpath().getAttr(0) = declaration and
      not exists(binding.getAttrpath().getAttr(1)) and result = expression(unparenthesized(binding.getExpression())))
  }
  /** An inherited helper keeps its source namespace and declaration spelling. */
  Node inheritedSource(Node declaration) {
    exists(Generated::Nix::InheritFrom clause |
      declaration = clause.getAttrs().getAnAttr() and
      result = expression(unparenthesized(clause.getExpression())))
  }
  predicate bareInherited(Node declaration) {
    exists(Node clause | clause.getKind() = "Inherit" and declaration = inheritedToken(clause))
  }
  Node listElement(Node list, int index) {
    result = list.(Generated::Nix::ListExpression).getElement(index)
  }
  predicate listExpression(Node node) { node instanceof Generated::Nix::ListExpression }

  private Generated::Nix::AstNode stringChild(Generated::Nix::AstNode text, int index) {
    result = text.(Generated::Nix::StringExpression).getChild(index)
    or result = text.(Generated::Nix::IndentedStringExpression).getChild(index)
  }

  bindingset[value]
  private string unescapeCharacter(string value) {
    value = "n" and result = "\n"
    or value = "r" and result = "\r"
    or value = "t" and result = "\t"
    or not value in ["n", "r", "t"] and result = value
  }

  private string stringPart(Generated::Nix::AstNode text, int index) {
    exists(Generated::Nix::AstNode child, string raw |
      child = stringChild(text, index) and
      (raw = child.(Generated::Nix::StringFragment).getValue() and
        (text instanceof Generated::Nix::StringExpression and
           result = raw.regexpReplaceAll("\r\n?", "\n")
         or text instanceof Generated::Nix::IndentedStringExpression and
           (index = 0 and result = raw.regexpReplaceAll("^ *\n", "")
            or index != 0 and result = raw))
       or child instanceof Generated::Nix::DollarEscape and raw = "" and result = ""
       or raw = child.(Generated::Nix::EscapeSequence).getValue() and
         (text instanceof Generated::Nix::StringExpression and
            result = unescapeCharacter(raw.substring(1, raw.length()))
          or text instanceof Generated::Nix::IndentedStringExpression and
            (raw = "'''" and result = "''"
             or raw != "'''" and result = unescapeCharacter(raw.substring(3, raw.length()))))))
  }

  // Escaped whitespace ends indentation in Nix's minimum-indent pass, even
  // when its decoded value is a space or newline. Protect it for that pass.
  private string indentationPart(Generated::Nix::AstNode text, int index) {
    exists(string value | value = stringPart(text, index) |
      stringChild(text, index) instanceof Generated::Nix::EscapeSequence and result = "x"
      or not stringChild(text, index) instanceof Generated::Nix::EscapeSequence and result = value)
  }

  bindingset[text]
  private predicate stringLine(string text, int start, string line) {
    (start = 0 or start in [1 .. text.length()] and text.substring(start - 1, start) = "\n") and
    line = text.substring(start, text.length()).regexpCapture("([^\n]*)(\n(.|\n)*)?", 1)
  }

  bindingset[text]
  private int leadingSpaces(string text) {
    result = text.regexpCapture("( *)(.|\n)*", 1).length()
  }

  private int minimumIndent(Generated::Nix::AstNode text) {
    exists(string value |
      value = concat(int i | exists(stringChild(text, i)) | indentationPart(text, i), "" order by i) and
      (result = min(string line | stringLine(value, _, line) and not line.regexpMatch(" *") |
          leadingSpaces(line))
       or not exists(string line | stringLine(value, _, line) and not line.regexpMatch(" *")) and
          result = value.length()))
  }

  bindingset[text, value]
  private string stripIndentation(Generated::Nix::AstNode text, string value) {
    exists(int indent, string stripped |
      indent = minimumIndent(text) and
      stripped = concat(int start, string line, int drop |
        stringLine(value, start, line) and
        (leadingSpaces(line) < indent and drop = leadingSpaces(line)
         or leadingSpaces(line) >= indent and drop = indent) |
        line.substring(drop, line.length()), "\n" order by start) and
      // Nix removes a trailing spaces-only line only within the final token.
      (exists(int last | exists(stringChild(text, last)) and not exists(stringChild(text, last + 1)) and
          stringPart(text, last).regexpMatch("(.|\n)*\n(.|\n)*")) and
         result = stripped.regexpReplaceAll("\n *\\z", "\n")
       or not exists(int last | exists(stringChild(text, last)) and not exists(stringChild(text, last + 1)) and
          stringPart(text, last).regexpMatch("(.|\n)*\n(.|\n)*")) and result = stripped))
  }

  /** One decoder for literal strings; lexical name callers retain their narrower guard. */
  private string decodedString(Generated::Nix::AstNode text) {
    (text instanceof Generated::Nix::StringExpression or text instanceof Generated::Nix::IndentedStringExpression) and
    forall(Generated::Nix::AstNode child | child = stringChild(text, _) |
      child instanceof Generated::Nix::StringFragment or child instanceof Generated::Nix::EscapeSequence or
      child instanceof Generated::Nix::DollarEscape) and
    exists(string value |
      value = concat(int i | exists(stringChild(text, i)) | stringPart(text, i), "" order by i) and
      (text instanceof Generated::Nix::StringExpression and result = value
       or text instanceof Generated::Nix::IndentedStringExpression and result = stripIndentation(text, value)))
  }

  /** Authenticated literal strings; interpolated and computed elements remain unknown. */
  string literalString(Node node) { result = decodedString(node) }

  string integerText(Node node) {
    result = node.(Generated::Nix::IntegerExpression).getValue() and
    result.regexpMatch("0|[1-9][0-9]*")
    or exists(Generated::Nix::UnaryExpression unary, string magnitude |
      unary = unparenthesized(node) and unary.getOperator() = "-" and
      magnitude = unary.getArgument().(Generated::Nix::IntegerExpression).getValue() and
      magnitude.regexpMatch("[1-9][0-9]*") and result = "-" + magnitude)
  }

}

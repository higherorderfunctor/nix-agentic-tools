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
    result = decodePart(value.regexpCapture("([^|]*)\\|([0-9]+)", number))
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
      exists(string root, string path, string hash |
        nx_files(this.getSourceFile(), root, path, hash, _) and
        result = part(root) + "|" + part(path) + "|" + part(hash)
      )
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
      result = concat(int i, Generated::Nix::StringFragment fragment |
        fragment = text.getChild(i) | fragment.getValue(), "" order by i)
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

}

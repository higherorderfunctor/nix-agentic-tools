/** Evaluator labels with optional admitted files, points and syntax candidates. */
import nix.Ast
import nix.Targets
private import nix.internal.Evaluation
private import nix.internal.RawBridge

module Origin {
  class Origin extends @nx_origin {
    string getLabel() { nx_origins(this, result, _) }
    string getRelativePath() {
      exists(@nx_file file | nx_origin_files(this, file) and nx_files(file, _, result, _, _))
    }
    int getLine() { nx_origin_positions(this, result, _, "utf8-byte-1-based") }
    int getColumn() { nx_origin_positions(this, _, result, "utf8-byte-1-based") }
    Ast::Binding getACandidate(Targets::Target target, string pathJson) {
      exists(@nx_file file, RawBridge::Anchor anchor |
        nx_origin_files(this, file) and nx_target_inputs(target, file, _) and
        nx_anchors(anchor, file, _, _, _, _) and anchor.getUniqueNode() = result and
        Evaluation::pathJson(result) = pathJson
      )
    }
    bindingset[target, pathJson]
    string getAssociationQuality(Targets::Target target, string pathJson) {
      exists(int candidates | candidates = count(this.getACandidate(target, pathJson)) |
        candidates = 0 and result = "unmapped"
        or candidates = 1 and result = "unique"
        or candidates > 1 and result = "ambiguous"
      )
    }
    string toString() { result = this.getLabel() }
  }
}

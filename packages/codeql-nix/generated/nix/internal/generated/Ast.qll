/**
* CodeQL library for Nix
          * Automatically generated from the tree-sitter grammar; do not edit
*/

import codeql.Locations as L

/** Holds if the database is an overlay. */overlay[local] private predicate isOverlay() { databaseMetadata("isOverlay", "true") }

/** Holds if `loc` is in the `file` and is part of the overlay base database. */overlay[local] private predicate discardableLocation(@file file, @location_default loc) { (not (isOverlay())) and (locations_default(loc, file, _, _, _, _)) }

/** Holds if `loc` should be discarded, because it is part of the overlay base and is in a file that was also extracted as part of the overlay database. */overlay[discard_entity] private predicate discardLocation(@location_default loc) { exists(@file file, string path | files(file, path) | (discardableLocation(file, loc)) and (overlayChangedFiles(path))) }

overlay[local] module Nix { 
  private module F = Nix;
  /** The base class for all AST nodes */class AstNode extends @nix_ast_node { 
  /** Gets a string representation of this element. */string toString() { result = this.getAPrimaryQlClass() }
  /** Gets the location of this element. */final L::Location getLocation() { nix_ast_node_location(this, result) }
  /** Gets the parent of this element. */final F::AstNode getParent() { nix_ast_node_parent(this, result, _) }
  /** Gets the index of this node among the children of its parent. */final int getParentIndex() { nix_ast_node_parent(this, _, result) }
  /** Gets a field or child node of this node. */F::AstNode getAFieldOrChild() { none() }
  /** Gets the name of the primary QL class for this element. */string getAPrimaryQlClass() { result = "???" }
  /** Gets a comma-separated list of the names of the primary CodeQL classes to which this element belongs. */string getPrimaryQlClasses() { result = concat(this.getAPrimaryQlClass(), ",") }
}
  /** A token. */class Token extends @nix_token, F::AstNode { 
  /** Gets the value of this token. */final string getValue() { nix_tokeninfo(this, _, result) }
  /** Gets a string representation of this element. */final override string toString() { result = this.getValue() }
  /** Gets the name of the primary QL class for this element. */override string getAPrimaryQlClass() { result = "Token" }
}
  /** A reserved word. */class ReservedWord extends @nix_reserved_word, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "ReservedWord" }
}
  /** Gets the file containing the given `node`. */private @file getNodeFile(@nix_ast_node node) { exists(@location_default loc | nix_ast_node_location(node, loc) | locations_default(loc, result, _, _, _, _)) }
  /** Holds if `node` is in the `file` and is part of the overlay base database. */private predicate discardableAstNode(@file file, @nix_ast_node node) { (not (isOverlay())) and (file = getNodeFile(node)) }
  /** Holds if `node` should be discarded, because it is part of the overlay base and is in a file that was also extracted as part of the overlay database. */overlay[discard_entity] private predicate discardAstNode(@nix_ast_node node) { exists(@file file, string path | files(file, path) | (discardableAstNode(file, node)) and (overlayChangedFiles(path))) }
  class UnderscoreExpression extends @nix_underscore_expression, F::AstNode { 
}
  /** A class representing `apply_expression` nodes. */class ApplyExpression extends @nix_apply_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "ApplyExpression" }
  /** Gets the node corresponding to the field `argument`. */final F::AstNode getArgument() { nix_apply_expression_def(this, result, _) }
  /** Gets the node corresponding to the field `function`. */final F::AstNode getFunction() { nix_apply_expression_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_apply_expression_def(this, result, _)) or (nix_apply_expression_def(this, _, result)) }
}
  /** A class representing `assert_expression` nodes. */class AssertExpression extends @nix_assert_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "AssertExpression" }
  /** Gets the node corresponding to the field `body`. */final F::AstNode getBody() { nix_assert_expression_def(this, result, _) }
  /** Gets the node corresponding to the field `condition`. */final F::UnderscoreExpression getCondition() { nix_assert_expression_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_assert_expression_def(this, result, _)) or (nix_assert_expression_def(this, _, result)) }
}
  /** A class representing `attrpath` nodes. */class Attrpath extends @nix_attrpath, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Attrpath" }
  /** Gets the node corresponding to the field `attr`. */final F::AstNode getAttr(int i) { nix_attrpath_attr(this, i, result) }
  /** Gets the node corresponding to the field `attr`. */final F::AstNode getAnAttr() { result = this.getAttr(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_attrpath_attr(this, _, result)) }
}
  /** A class representing `attrset_expression` nodes. */class AttrsetExpression extends @nix_attrset_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "AttrsetExpression" }
  /** Gets the child of this node. */final F::BindingSet getChild() { nix_attrset_expression_child(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_attrset_expression_child(this, result)) }
}
  /** A class representing `binary_expression` nodes. */class BinaryExpression extends @nix_binary_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "BinaryExpression" }
  /** Gets the node corresponding to the field `left`. */final F::AstNode getLeft() { nix_binary_expression_def(this, result, _, _) }
  /** Gets the node corresponding to the field `operator`. */final string getOperator() { exists(int value | nix_binary_expression_def(this, _, value, _) | ((result = "!=") and (value = 0)) or ((result = "&&") and (value = 1)) or ((result = "*") and (value = 2)) or ((result = "+") and (value = 3)) or ((result = "++") and (value = 4)) or ((result = "-") and (value = 5)) or ((result = "->") and (value = 6)) or ((result = "/") and (value = 7)) or ((result = "//") and (value = 8)) or ((result = "<") and (value = 9)) or ((result = "<=") and (value = 10)) or ((result = "==") and (value = 11)) or ((result = ">") and (value = 12)) or ((result = ">=") and (value = 13)) or ((result = "||") and (value = 14))) }
  /** Gets the node corresponding to the field `right`. */final F::AstNode getRight() { nix_binary_expression_def(this, _, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_binary_expression_def(this, result, _, _)) or (nix_binary_expression_def(this, _, _, result)) }
}
  /** A class representing `binding` nodes. */class Binding extends @nix_binding, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Binding" }
  /** Gets the node corresponding to the field `attrpath`. */final F::Attrpath getAttrpath() { nix_binding_def(this, result, _) }
  /** Gets the node corresponding to the field `expression`. */final F::UnderscoreExpression getExpression() { nix_binding_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_binding_def(this, result, _)) or (nix_binding_def(this, _, result)) }
}
  /** A class representing `binding_set` nodes. */class BindingSet extends @nix_binding_set, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "BindingSet" }
  /** Gets the node corresponding to the field `binding`. */final F::AstNode getBinding(int i) { nix_binding_set_binding(this, i, result) }
  /** Gets the node corresponding to the field `binding`. */final F::AstNode getABinding() { result = this.getBinding(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_binding_set_binding(this, _, result)) }
}
  /** A class representing `comment` tokens. */class Comment extends @nix_token_comment, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Comment" }
}
  /** A class representing `dollar_escape` tokens. */class DollarEscape extends @nix_token_dollar_escape, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "DollarEscape" }
}
  /** A class representing `ellipses` tokens. */class Ellipses extends @nix_token_ellipses, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Ellipses" }
}
  /** A class representing `escape_sequence` tokens. */class EscapeSequence extends @nix_token_escape_sequence, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "EscapeSequence" }
}
  /** A class representing `float_expression` tokens. */class FloatExpression extends @nix_token_float_expression, F::Token, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "FloatExpression" }
}
  /** A class representing `formal` nodes. */class Formal extends @nix_formal, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Formal" }
  /** Gets the node corresponding to the field `default`. */final F::UnderscoreExpression getDefault() { nix_formal_default(this, result) }
  /** Gets the node corresponding to the field `name`. */final F::Identifier getName() { nix_formal_def(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_formal_default(this, result)) or (nix_formal_def(this, result)) }
}
  /** A class representing `formals` nodes. */class Formals extends @nix_formals, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Formals" }
  /** Gets the node corresponding to the field `ellipses`. */final F::Ellipses getEllipses() { nix_formals_ellipses(this, result) }
  /** Gets the node corresponding to the field `formal`. */final F::Formal getFormal(int i) { nix_formals_formal(this, i, result) }
  /** Gets the node corresponding to the field `formal`. */final F::Formal getAFormal() { result = this.getFormal(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_formals_ellipses(this, result)) or (nix_formals_formal(this, _, result)) }
}
  /** A class representing `function_expression` nodes. */class FunctionExpression extends @nix_function_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "FunctionExpression" }
  /** Gets the node corresponding to the field `body`. */final F::AstNode getBody() { nix_function_expression_def(this, result) }
  /** Gets the node corresponding to the field `formals`. */final F::Formals getFormals() { nix_function_expression_formals(this, result) }
  /** Gets the node corresponding to the field `universal`. */final F::Identifier getUniversal() { nix_function_expression_universal(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_function_expression_def(this, result)) or (nix_function_expression_formals(this, result)) or (nix_function_expression_universal(this, result)) }
}
  /** A class representing `has_attr_expression` nodes. */class HasAttrExpression extends @nix_has_attr_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "HasAttrExpression" }
  /** Gets the node corresponding to the field `attrpath`. */final F::Attrpath getAttrpath() { nix_has_attr_expression_def(this, result, _, _) }
  /** Gets the node corresponding to the field `expression`. */final F::AstNode getExpression() { nix_has_attr_expression_def(this, _, result, _) }
  /** Gets the node corresponding to the field `operator`. */final string getOperator() { exists(int value | nix_has_attr_expression_def(this, _, _, value) | ((result = "?") and (value = 0))) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_has_attr_expression_def(this, result, _, _)) or (nix_has_attr_expression_def(this, _, result, _)) }
}
  /** A class representing `hpath_expression` nodes. */class HpathExpression extends @nix_hpath_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "HpathExpression" }
  /** Gets the `i`th child of this node. */final F::AstNode getChild(int i) { nix_hpath_expression_child(this, i, result) }
  /** Gets the `i`th child of this node. */final F::AstNode getAChild() { result = this.getChild(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_hpath_expression_child(this, _, result)) }
}
  /** A class representing `identifier` tokens. */class Identifier extends @nix_token_identifier, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Identifier" }
}
  /** A class representing `if_expression` nodes. */class IfExpression extends @nix_if_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "IfExpression" }
  /** Gets the node corresponding to the field `alternative`. */final F::UnderscoreExpression getAlternative() { nix_if_expression_def(this, result, _, _) }
  /** Gets the node corresponding to the field `condition`. */final F::UnderscoreExpression getCondition() { nix_if_expression_def(this, _, result, _) }
  /** Gets the node corresponding to the field `consequence`. */final F::UnderscoreExpression getConsequence() { nix_if_expression_def(this, _, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_if_expression_def(this, result, _, _)) or (nix_if_expression_def(this, _, result, _)) or (nix_if_expression_def(this, _, _, result)) }
}
  /** A class representing `indented_string_expression` nodes. */class IndentedStringExpression extends @nix_indented_string_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "IndentedStringExpression" }
  /** Gets the `i`th child of this node. */final F::AstNode getChild(int i) { nix_indented_string_expression_child(this, i, result) }
  /** Gets the `i`th child of this node. */final F::AstNode getAChild() { result = this.getChild(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_indented_string_expression_child(this, _, result)) }
}
  /** A class representing `inherit` nodes. */class Inherit extends @nix_inherit, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Inherit" }
  /** Gets the node corresponding to the field `attrs`. */final F::InheritedAttrs getAttrs() { nix_inherit_def(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_inherit_def(this, result)) }
}
  /** A class representing `inherit_from` nodes. */class InheritFrom extends @nix_inherit_from, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "InheritFrom" }
  /** Gets the node corresponding to the field `attrs`. */final F::InheritedAttrs getAttrs() { nix_inherit_from_def(this, result, _) }
  /** Gets the node corresponding to the field `expression`. */final F::UnderscoreExpression getExpression() { nix_inherit_from_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_inherit_from_def(this, result, _)) or (nix_inherit_from_def(this, _, result)) }
}
  /** A class representing `inherited_attrs` nodes. */class InheritedAttrs extends @nix_inherited_attrs, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "InheritedAttrs" }
  /** Gets the node corresponding to the field `attr`. */final F::AstNode getAttr(int i) { nix_inherited_attrs_attr(this, i, result) }
  /** Gets the node corresponding to the field `attr`. */final F::AstNode getAnAttr() { result = this.getAttr(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_inherited_attrs_attr(this, _, result)) }
}
  /** A class representing `integer_expression` tokens. */class IntegerExpression extends @nix_token_integer_expression, F::Token, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "IntegerExpression" }
}
  /** A class representing `interpolation` nodes. */class Interpolation extends @nix_interpolation, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "Interpolation" }
  /** Gets the node corresponding to the field `expression`. */final F::UnderscoreExpression getExpression() { nix_interpolation_def(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_interpolation_def(this, result)) }
}
  /** A class representing `let_attrset_expression` nodes. */class LetAttrsetExpression extends @nix_let_attrset_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "LetAttrsetExpression" }
  /** Gets the child of this node. */final F::BindingSet getChild() { nix_let_attrset_expression_child(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_let_attrset_expression_child(this, result)) }
}
  /** A class representing `let_expression` nodes. */class LetExpression extends @nix_let_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "LetExpression" }
  /** Gets the node corresponding to the field `body`. */final F::AstNode getBody() { nix_let_expression_def(this, result) }
  /** Gets the child of this node. */final F::BindingSet getChild() { nix_let_expression_child(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_let_expression_def(this, result)) or (nix_let_expression_child(this, result)) }
}
  /** A class representing `list_expression` nodes. */class ListExpression extends @nix_list_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "ListExpression" }
  /** Gets the node corresponding to the field `element`. */final F::AstNode getElement(int i) { nix_list_expression_element(this, i, result) }
  /** Gets the node corresponding to the field `element`. */final F::AstNode getAnElement() { result = this.getElement(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_list_expression_element(this, _, result)) }
}
  /** A class representing `parenthesized_expression` nodes. */class ParenthesizedExpression extends @nix_parenthesized_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "ParenthesizedExpression" }
  /** Gets the node corresponding to the field `expression`. */final F::UnderscoreExpression getExpression() { nix_parenthesized_expression_def(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_parenthesized_expression_def(this, result)) }
}
  /** A class representing `path_expression` nodes. */class PathExpression extends @nix_path_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "PathExpression" }
  /** Gets the `i`th child of this node. */final F::AstNode getChild(int i) { nix_path_expression_child(this, i, result) }
  /** Gets the `i`th child of this node. */final F::AstNode getAChild() { result = this.getChild(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_path_expression_child(this, _, result)) }
}
  /** A class representing `path_fragment` tokens. */class PathFragment extends @nix_token_path_fragment, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "PathFragment" }
}
  /** A class representing `rec_attrset_expression` nodes. */class RecAttrsetExpression extends @nix_rec_attrset_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "RecAttrsetExpression" }
  /** Gets the child of this node. */final F::BindingSet getChild() { nix_rec_attrset_expression_child(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_rec_attrset_expression_child(this, result)) }
}
  /** A class representing `select_expression` nodes. */class SelectExpression extends @nix_select_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "SelectExpression" }
  /** Gets the node corresponding to the field `attrpath`. */final F::Attrpath getAttrpath() { nix_select_expression_def(this, result, _) }
  /** Gets the node corresponding to the field `default`. */final F::AstNode getDefault() { nix_select_expression_default(this, result) }
  /** Gets the node corresponding to the field `expression`. */final F::AstNode getExpression() { nix_select_expression_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_select_expression_def(this, result, _)) or (nix_select_expression_default(this, result)) or (nix_select_expression_def(this, _, result)) }
}
  /** A class representing `source_code` nodes. */class SourceCode extends @nix_source_code, F::AstNode { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "SourceCode" }
  /** Gets the node corresponding to the field `expression`. */final F::UnderscoreExpression getExpression() { nix_source_code_expression(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_source_code_expression(this, result)) }
}
  /** A class representing `spath_expression` tokens. */class SpathExpression extends @nix_token_spath_expression, F::Token, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "SpathExpression" }
}
  /** A class representing `string_expression` nodes. */class StringExpression extends @nix_string_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "StringExpression" }
  /** Gets the `i`th child of this node. */final F::AstNode getChild(int i) { nix_string_expression_child(this, i, result) }
  /** Gets the `i`th child of this node. */final F::AstNode getAChild() { result = this.getChild(_) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_string_expression_child(this, _, result)) }
}
  /** A class representing `string_fragment` tokens. */class StringFragment extends @nix_token_string_fragment, F::AstNode, F::Token { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "StringFragment" }
}
  /** A class representing `unary_expression` nodes. */class UnaryExpression extends @nix_unary_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "UnaryExpression" }
  /** Gets the node corresponding to the field `argument`. */final F::AstNode getArgument() { nix_unary_expression_def(this, result, _) }
  /** Gets the node corresponding to the field `operator`. */final string getOperator() { exists(int value | nix_unary_expression_def(this, _, value) | ((result = "!") and (value = 0)) or ((result = "-") and (value = 1))) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_unary_expression_def(this, result, _)) }
}
  /** A class representing `uri_expression` tokens. */class UriExpression extends @nix_token_uri_expression, F::Token, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "UriExpression" }
}
  /** A class representing `variable_expression` nodes. */class VariableExpression extends @nix_variable_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "VariableExpression" }
  /** Gets the node corresponding to the field `name`. */final F::Identifier getName() { nix_variable_expression_def(this, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_variable_expression_def(this, result)) }
}
  /** A class representing `with_expression` nodes. */class WithExpression extends @nix_with_expression, F::UnderscoreExpression { 
  /** Gets the name of the primary QL class for this element. */final override string getAPrimaryQlClass() { result = "WithExpression" }
  /** Gets the node corresponding to the field `body`. */final F::AstNode getBody() { nix_with_expression_def(this, result, _) }
  /** Gets the node corresponding to the field `environment`. */final F::UnderscoreExpression getEnvironment() { nix_with_expression_def(this, _, result) }
  /** Gets a field or child node of this node. */final override F::AstNode getAFieldOrChild() { (nix_with_expression_def(this, result, _)) or (nix_with_expression_def(this, _, result)) }
}
  /** Provides predicates for mapping AST nodes to their named children. */module PrintAst { 
  /** Gets a child of `node` returned by the member predicate with the given `name`. If the predicate takes an index argument, `i` is bound to that index, otherwise `i` is `-1` (which is never a valid index). */F::AstNode getChild(F::AstNode node, string name, int i) { ((result = node.(ApplyExpression).getArgument()) and (i = -1) and (name = "getArgument")) or ((result = node.(ApplyExpression).getFunction()) and (i = -1) and (name = "getFunction")) or ((result = node.(AssertExpression).getBody()) and (i = -1) and (name = "getBody")) or ((result = node.(AssertExpression).getCondition()) and (i = -1) and (name = "getCondition")) or ((result = node.(Attrpath).getAttr(i)) and (name = "getAttr")) or ((result = node.(AttrsetExpression).getChild()) and (i = -1) and (name = "getChild")) or ((result = node.(BinaryExpression).getLeft()) and (i = -1) and (name = "getLeft")) or ((result = node.(BinaryExpression).getRight()) and (i = -1) and (name = "getRight")) or ((result = node.(Binding).getAttrpath()) and (i = -1) and (name = "getAttrpath")) or ((result = node.(Binding).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(BindingSet).getBinding(i)) and (name = "getBinding")) or ((result = node.(Formal).getDefault()) and (i = -1) and (name = "getDefault")) or ((result = node.(Formal).getName()) and (i = -1) and (name = "getName")) or ((result = node.(Formals).getEllipses()) and (i = -1) and (name = "getEllipses")) or ((result = node.(Formals).getFormal(i)) and (name = "getFormal")) or ((result = node.(FunctionExpression).getBody()) and (i = -1) and (name = "getBody")) or ((result = node.(FunctionExpression).getFormals()) and (i = -1) and (name = "getFormals")) or ((result = node.(FunctionExpression).getUniversal()) and (i = -1) and (name = "getUniversal")) or ((result = node.(HasAttrExpression).getAttrpath()) and (i = -1) and (name = "getAttrpath")) or ((result = node.(HasAttrExpression).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(HpathExpression).getChild(i)) and (name = "getChild")) or ((result = node.(IfExpression).getAlternative()) and (i = -1) and (name = "getAlternative")) or ((result = node.(IfExpression).getCondition()) and (i = -1) and (name = "getCondition")) or ((result = node.(IfExpression).getConsequence()) and (i = -1) and (name = "getConsequence")) or ((result = node.(IndentedStringExpression).getChild(i)) and (name = "getChild")) or ((result = node.(Inherit).getAttrs()) and (i = -1) and (name = "getAttrs")) or ((result = node.(InheritFrom).getAttrs()) and (i = -1) and (name = "getAttrs")) or ((result = node.(InheritFrom).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(InheritedAttrs).getAttr(i)) and (name = "getAttr")) or ((result = node.(Interpolation).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(LetAttrsetExpression).getChild()) and (i = -1) and (name = "getChild")) or ((result = node.(LetExpression).getBody()) and (i = -1) and (name = "getBody")) or ((result = node.(LetExpression).getChild()) and (i = -1) and (name = "getChild")) or ((result = node.(ListExpression).getElement(i)) and (name = "getElement")) or ((result = node.(ParenthesizedExpression).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(PathExpression).getChild(i)) and (name = "getChild")) or ((result = node.(RecAttrsetExpression).getChild()) and (i = -1) and (name = "getChild")) or ((result = node.(SelectExpression).getAttrpath()) and (i = -1) and (name = "getAttrpath")) or ((result = node.(SelectExpression).getDefault()) and (i = -1) and (name = "getDefault")) or ((result = node.(SelectExpression).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(SourceCode).getExpression()) and (i = -1) and (name = "getExpression")) or ((result = node.(StringExpression).getChild(i)) and (name = "getChild")) or ((result = node.(UnaryExpression).getArgument()) and (i = -1) and (name = "getArgument")) or ((result = node.(VariableExpression).getName()) and (i = -1) and (name = "getName")) or ((result = node.(WithExpression).getBody()) and (i = -1) and (name = "getBody")) or ((result = node.(WithExpression).getEnvironment()) and (i = -1) and (name = "getEnvironment")) }
}
}

module NixFinal { 
  private module F = Nix;
  import F
  final class AstNode = F::AstNode;
  final class Token = F::Token;
  final class ReservedWord = F::ReservedWord;
  final class UnderscoreExpression = F::UnderscoreExpression;
  final class ApplyExpression = F::ApplyExpression;
  final class AssertExpression = F::AssertExpression;
  final class Attrpath = F::Attrpath;
  final class AttrsetExpression = F::AttrsetExpression;
  final class BinaryExpression = F::BinaryExpression;
  final class Binding = F::Binding;
  final class BindingSet = F::BindingSet;
  final class Comment = F::Comment;
  final class DollarEscape = F::DollarEscape;
  final class Ellipses = F::Ellipses;
  final class EscapeSequence = F::EscapeSequence;
  final class FloatExpression = F::FloatExpression;
  final class Formal = F::Formal;
  final class Formals = F::Formals;
  final class FunctionExpression = F::FunctionExpression;
  final class HasAttrExpression = F::HasAttrExpression;
  final class HpathExpression = F::HpathExpression;
  final class Identifier = F::Identifier;
  final class IfExpression = F::IfExpression;
  final class IndentedStringExpression = F::IndentedStringExpression;
  final class Inherit = F::Inherit;
  final class InheritFrom = F::InheritFrom;
  final class InheritedAttrs = F::InheritedAttrs;
  final class IntegerExpression = F::IntegerExpression;
  final class Interpolation = F::Interpolation;
  final class LetAttrsetExpression = F::LetAttrsetExpression;
  final class LetExpression = F::LetExpression;
  final class ListExpression = F::ListExpression;
  final class ParenthesizedExpression = F::ParenthesizedExpression;
  final class PathExpression = F::PathExpression;
  final class PathFragment = F::PathFragment;
  final class RecAttrsetExpression = F::RecAttrsetExpression;
  final class SelectExpression = F::SelectExpression;
  final class SourceCode = F::SourceCode;
  final class SpathExpression = F::SpathExpression;
  final class StringExpression = F::StringExpression;
  final class StringFragment = F::StringFragment;
  final class UnaryExpression = F::UnaryExpression;
  final class UriExpression = F::UriExpression;
  final class VariableExpression = F::VariableExpression;
  final class WithExpression = F::WithExpression;
}


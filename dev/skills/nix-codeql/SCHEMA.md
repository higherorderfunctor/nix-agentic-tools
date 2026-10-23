# codeql-nix AST schema summary (generated from TreeSitter.qll, module NIX)

Every class below lives in module `NIX` (`import codeql.nix.Nix`, then refer to
`NIX::<Class>`; Nix.qll also aliases common ones without the prefix, e.g.
ApplyExpression, SelectExpression, VariableExpression, Binding, Identifier). All
classes extend AstNode, which has: getParent(), getParentIndex(),
getAFieldOrChild(), getLocation() (with getFile().getRelativePath(),
getStartLine()), toString(), getAPrimaryQlClass(). Token subclasses (Identifier,
StringFragment, ...) have getValue() returning the source text. Field getters
return the CST child for that tree-sitter field; parentheses are explicit
ParenthesizedExpression nodes.

- **AstNode** (@nix_ast_node): getParent() -> AstNode; getParentIndex() -> int
- **Token** (@nix_token, AstNode): getValue() -> string
- **ReservedWord** (@nix_reserved_word, Token)
- **UnderscoreExpression** (@nix_underscore_expression, AstNode)
- **ApplyExpression** (@nix_apply_expression, AstNode): getArgument() ->
  AstNode; getFunction() -> AstNode
- **AssertExpression** (@nix_assert_expression, AstNode): getBody() -> AstNode;
  getCondition() -> UnderscoreExpression
- **Attrpath** (@nix_attrpath, AstNode): getAttr(int i) -> AstNode
- **AttrsetExpression** (@nix_attrset_expression, AstNode): getChild() ->
  BindingSet
- **BinaryExpression** (@nix_binary_expression, AstNode): getLeft() -> AstNode;
  getOperator() -> string; getRight() -> AstNode [operator values: != && * +
  ++ - -> / // < <= == > >= ||]
- **Binding** (@nix_binding, AstNode): getAttrpath() -> Attrpath;
  getExpression() -> UnderscoreExpression
- **BindingSet** (@nix_binding_set, AstNode): getBinding(int i) -> AstNode
- **Comment** (@nix_token_comment, Token)
- **DollarEscape** (@nix_token_dollar_escape, Token)
- **Ellipses** (@nix_token_ellipses, Token)
- **EscapeSequence** (@nix_token_escape_sequence, Token)
- **FloatExpression** (@nix_token_float_expression, Token)
- **Formal** (@nix_formal, AstNode): getDefault() -> UnderscoreExpression;
  getName() -> Identifier
- **Formals** (@nix_formals, AstNode): getEllipses() -> Ellipses; getFormal(int
  i) -> Formal
- **FunctionExpression** (@nix_function_expression, AstNode): getBody() ->
  AstNode; getFormals() -> Formals; getUniversal() -> Identifier
- **HasAttrExpression** (@nix_has_attr_expression, AstNode): getAttrpath() ->
  Attrpath; getExpression() -> AstNode; getOperator() -> string [operator
  values: ?]
- **HpathExpression** (@nix_hpath_expression, AstNode): getChild(int i) ->
  AstNode
- **Identifier** (@nix_token_identifier, Token)
- **IfExpression** (@nix_if_expression, AstNode): getAlternative() ->
  UnderscoreExpression; getCondition() -> UnderscoreExpression; getConsequence()
  -> UnderscoreExpression
- **IndentedStringExpression** (@nix_indented_string_expression, AstNode):
  getChild(int i) -> AstNode
- **Inherit** (@nix_inherit, AstNode): getAttrs() -> InheritedAttrs
- **InheritFrom** (@nix_inherit_from, AstNode): getAttrs() -> InheritedAttrs;
  getExpression() -> UnderscoreExpression
- **InheritedAttrs** (@nix_inherited_attrs, AstNode): getAttr(int i) -> AstNode
- **IntegerExpression** (@nix_token_integer_expression, Token)
- **Interpolation** (@nix_interpolation, AstNode): getExpression() ->
  UnderscoreExpression
- **LetAttrsetExpression** (@nix_let_attrset_expression, AstNode): getChild() ->
  BindingSet
- **LetExpression** (@nix_let_expression, AstNode): getBody() -> AstNode;
  getChild() -> BindingSet
- **ListExpression** (@nix_list_expression, AstNode): getElement(int i) ->
  AstNode
- **ParenthesizedExpression** (@nix_parenthesized_expression, AstNode):
  getExpression() -> UnderscoreExpression
- **PathExpression** (@nix_path_expression, AstNode): getChild(int i) -> AstNode
- **PathFragment** (@nix_token_path_fragment, Token)
- **RecAttrsetExpression** (@nix_rec_attrset_expression, AstNode): getChild() ->
  BindingSet
- **SelectExpression** (@nix_select_expression, AstNode): getAttrpath() ->
  Attrpath; getDefault() -> AstNode; getExpression() -> AstNode
- **SourceCode** (@nix_source_code, AstNode): getExpression() ->
  UnderscoreExpression
- **SpathExpression** (@nix_token_spath_expression, Token)
- **StringExpression** (@nix_string_expression, AstNode): getChild(int i) ->
  AstNode
- **StringFragment** (@nix_token_string_fragment, Token)
- **UnaryExpression** (@nix_unary_expression, AstNode): getArgument() ->
  AstNode; getOperator() -> string [operator values: ! -]
- **UriExpression** (@nix_token_uri_expression, Token)
- **VariableExpression** (@nix_variable_expression, AstNode): getName() ->
  Identifier
- **WithExpression** (@nix_with_expression, AstNode): getBody() -> AstNode;
  getEnvironment() -> UnderscoreExpression

## Hand-written library modules (read the .qll for details)

- `codeql.nix.Nix` - aliases above plus helpers.
- `codeql.nix.Scope` - `class Scope` (let / let-attrset / rec / function),
  `Scope.definesName(string name, Identifier defNode)`, `class NameReference`
  (variable refs and `inherit x;` names; `getName()`),
  `predicate resolvesTo(NameReference ref, Scope scope)` (lexical only; does NOT
  model `with`), `predicate isUnusedBinding(Scope, string, Identifier)`.
- `codeql.nix.Strings`, `codeql.nix.Builtins`, `codeql.nix.Derivation`,
  `codeql.nix.Fetchers`, `codeql.nix.Taint` (light intra-file taint).

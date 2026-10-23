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

## Module-system evaluation tables

`import EvalTables` from the tiny library pack `nix-agentic-tools/eval-tables`.
Add that dependency alongside `jamiemagee/nix-all` in an ad hoc pack. Every
predicate carries a source name. `devenv` evaluates this repository's real
`dev/ai.nix` with the shared backend stubs; `home-manager` evaluates the same
owner imports with Home Manager stubs and default configuration; `facets`
evaluates the actual check module set without forcing check derivations. These
are module sets, not complete upstream devenv/Home Manager hosts.

| Predicate        | Columns in order                                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `evalSource`     | source, status, error, wallSeconds, peakMb, rowCounts                                                                               |
| `evalOption`     | source, path, type, typeDescription, highestPrio, isDefined, internal, readOnly, visible, hasDefault, hasApply, generated, instance |
| `evalOptionDecl` | source, path, file, line, column                                                                                                    |
| `evalDefinition` | source, path, file, line, column, moduleFile, priority, active, conditionCount, wins, aliasForward, kind                            |
| `evalModule`     | source, file, key, importedBy, disabled                                                                                             |
| `evalValue`      | source, path, kind, value                                                                                                           |

Paths use `lib.showOption`; files under the evaluated root are relative to it.
Positions are 1-based byte columns, compatible with the Nix AST. A definition's
literal position can differ from its module's `_file`; inherited/generated
positions are approximate, so inspect the AST before claiming an exact join.
Missing positions and priorities use `-1`; missing instance/importer strings are
empty. `visible` and `rowCounts` are JSON strings. Scalars are boolean, integer
or strings of at most 256 characters, with booleans/integers encoded as JSON
text. Store-path strings and structured values are omitted; derivation `outPath`
is never read.

Options include schemas from `getSubOptions` and actual configurations through
`valueMeta`, including instance definitions recollected with their original
module arguments. Repeated recursive declaration schemas stop at their cycle;
finite actual instances still recurse. Inactive `mkIf` rows describe the branch
root: its content is never inspected, even to enumerate children. Losing active
definitions remain visible. Their `kind` is weak head normal form `typeOf`,
including `set` for tagged sets; a catchable failure is `unknown` and an
inactive branch is `inactive`. `wins` means active and equal to the option's
highest priority, rather than a separate value comparison. `aliasForward` marks
priority 1500 as a forwarding heuristic; an explicit `mkOverride 1500` also
receives the flag. `_module.*` rows are retained.

Generation-local data lives in `db/../eval/rows.model.yml`; the query client
adds its extension pack automatically. `evalSource.status` is `ok` or `failed`;
check it before interpreting missing rows. A failing source records a capped
error and does not block database publication. Both AST and evaluation describe
the generation snapshot; changing an ad hoc source expression in the database
descriptor invalidates the lifecycle stamp. Source times and RSS describe each
whole dump process, not option-level cost.

import nix.Ast

private string id(Ast::AstNode node) {
  result = node.getLocation().getStartColumn().toString() + ":" +
    node.getLocation().getEndColumn().toString()
}

from Ast::AstNode node, string role, int index, string value
where
  node.getRelativePath() = "forms.nix" and
  (
    role = "kind" and index = 0 and
    (
      node instanceof Ast::AttrSet and value = "set" or
      node instanceof Ast::Binding and value = "binding" or
      node instanceof Ast::Identifier and value = "identifier" or
      node instanceof Ast::LetExpr and value = "let" or
      node instanceof Ast::FunctionExpr and value = "function"
    )
    or role = "name" and index = 0 and value = node.(Ast::Identifier).getName()
    or role = "segment" and value = node.(Ast::Binding).getSegment(index)
    or role = "value" and index = 0 and value = id(node.(Ast::Binding).getValue())
    or role = "body" and index = 0 and
      (value = id(node.(Ast::LetExpr).getBody()) or
       value = id(node.(Ast::FunctionExpr).getBody()))
    or role = "parameter" and index = 0 and value = id(node.(Ast::FunctionExpr).getParameter())
    or role = "binding" and
      exists(Ast::Binding binding |
        binding = node.(Ast::AttrSet).getABinding() or
        binding = node.(Ast::LetExpr).getABinding()
      | index = binding.getLocation().getStartColumn() and value = id(binding))
  )
select id(node), role, index, value

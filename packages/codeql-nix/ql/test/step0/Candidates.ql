import nix.Ast

from string file, string check, int total
where
  file in ["candidates.nix", "forms.nix", "malformed.nix", "negative.nix"] and
  (
    file = "candidates.nix" and check = "bindings.with.segments" and
    total = count(Ast::Binding binding |
      binding.getRelativePath() = file and exists(binding.getSegment(_)))
    or check = "demo.answer" and
    total = count(Ast::Binding binding |
      binding.getRelativePath() = file and binding.getLiteralSegmentCount() = 2 and
      binding.getSegment(0) = "demo" and binding.getSegment(1) = "answer")
    or check = "malformed.binding" and
    total = count(Ast::Binding binding |
      binding.getRelativePath() = file and binding.getLiteralSegmentCount() = 2 and
      binding.getSegment(0) = "demo" and binding.getSegment(1) = "broken")
    or check = "one.dotted.segment" and
    total = count(Ast::Binding binding |
      binding.getRelativePath() = file and binding.getLiteralSegmentCount() = 1 and
      binding.getSegment(0) = "demo.answer")
    or file = "negative.nix" and check = "five.forms" and
    total = count(Ast::AstNode node |
      node.getRelativePath() = file and
      (node instanceof Ast::AttrSet or node instanceof Ast::Binding or
       node instanceof Ast::Identifier or node instanceof Ast::LetExpr or
       node instanceof Ast::FunctionExpr))
  )
select file, check, total

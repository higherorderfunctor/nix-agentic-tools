/** Shared metadata witnesses and exact syntax-path encoding; no value inference. */
import nix.Ast

module Evaluation {
  predicate observed(@nx_observation observation) {
    exists(@nx_request request |
      nx_observations(observation, request, "pre-apply-metadata", "observed") and
      nx_request_results(request, ["complete", "partial"], _, _)
    )
  }

  bindingset[character]
  private string escaped(string character) {
    character = "\"" and result = "\\\""
    or character = "\\" and result = "\\\\"
    or character.codePointAt(0) = 8 and result = "\\b"
    or character = "\t" and result = "\\t"
    or character = "\n" and result = "\\n"
    or character.codePointAt(0) = 12 and result = "\\f"
    or character = "\r" and result = "\\r"
    or exists(int code | code = character.codePointAt(0) |
      code in [0 .. 31] and not code in [8, 9, 10, 12, 13] and
      result = "\\u00" + "0123456789abcdef".charAt(code / 16) + "0123456789abcdef".charAt(code % 16)
      or code > 31 and not character in ["\"", "\\"] and result = character
    )
  }

  bindingset[text]
  string quoted(string text) {
    // Slice whole code points: charAt cannot return an isolated surrogate.
    result = "\"" + concat(int i, int width |
      i in [0 .. text.length() - 1] and
      (text.codePointAt(i) <= 65535 and width = 1
       or text.codePointAt(i) > 65535 and width = 2) |
      escaped(text.substring(i, i + width)), "" order by i) + "\""
  }

  string pathJson(Ast::Binding binding) {
    result = "[" + concat(int i | exists(binding.getSegment(i)) |
      quoted(binding.getSegment(i)), "," order by i) + "]"
  }
}

# Lexical helpers shared by the authored option type and wire parser.
# cspell:ignore feff
{lib}: let
  # JavaScript `\s` is a fixed Unicode set. Nix's POSIX regex engine covers
  # only the ASCII subset, so spell out the complete set once and share it
  # across both entry paths.
  whitespace =
    map
    (code: builtins.fromJSON ("\"\\u" + code + "\""))
    [
      "0009"
      "000a"
      "000b"
      "000c"
      "000d"
      "0020"
      "00a0"
      "1680"
      "2000"
      "2001"
      "2002"
      "2003"
      "2004"
      "2005"
      "2006"
      "2007"
      "2008"
      "2009"
      "200a"
      "2028"
      "2029"
      "202f"
      "205f"
      "3000"
      "feff"
    ];
in {
  hasJsWhitespace = s:
    lib.any (character: lib.hasInfix character s) whitespace;

  isJsWhitespaceOnly = s:
    lib.replaceStrings whitespace (map (_: "") whitespace) s == "";
}

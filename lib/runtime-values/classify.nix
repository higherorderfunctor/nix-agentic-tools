# cspell:ignore apikey clientsecret privatekey
{lib}: let
  separators = ["-" "." "_"];
  secretSuffixes = [
    ["access" "key"]
    ["api" "key"]
    ["apikey"]
    ["authorization"]
    ["clientsecret"]
    ["credential"]
    ["credentials"]
    ["passwd"]
    ["password"]
    ["pat"]
    ["private" "key"]
    ["privatekey"]
    ["secret"]
    ["token"]
    ["tokens"]
  ];
  segments = name: let
    normalized =
      (lib.foldl' (state: char: {
          previous = char;
          text =
            state.text
            + (
              if builtins.match "[A-Z]" char != null && builtins.match "[a-z0-9]" state.previous != null
              then "_"
              else ""
            )
            + char;
        }) {
          previous = "_";
          text = "";
        }
        (lib.stringToCharacters name)).text;
  in
    builtins.filter (segment: segment != "")
    (lib.splitString "_" (lib.toLower (lib.replaceStrings separators (map (_: "_") separators) normalized)));
in {
  classify = {
    hints ? {},
    path,
    secretContainer ? false,
  }: let
    parts =
      if path == []
      then []
      else segments (lib.last path);
    # Empty paths and one-word names cannot match a two-word phrase.
    hasSuffix = suffix:
      builtins.length parts
      >= builtins.length suffix
      && lib.drop (builtins.length parts - builtins.length suffix) parts == suffix;
  in
    hints.keyring or false
    || secretContainer
    || lib.any hasSuffix secretSuffixes;
}

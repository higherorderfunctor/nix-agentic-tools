# cspell:ignore apikey clientsecret
{lib}: let
  segments = name: let
    chars = lib.stringToCharacters name;
    normalized =
      (lib.foldl' (state: char: {
          text =
            state.text
            + (
              if builtins.match "[A-Z]" char != null && builtins.match "[a-z0-9]" state.previous != null
              then "_"
              else ""
            )
            + char;
          previous = char;
        }) {
          text = "";
          previous = "_";
        }
        chars).text;
  in
    builtins.filter (segment: segment != "")
    (lib.splitString "_" (lib.toLower normalized));
  contains = values: parts: lib.any (part: builtins.elem part values) parts;
in {
  classify = {
    path,
    hints ? {},
    secretContainer ? false,
  }: let
    parts =
      if path == []
      then []
      else segments (lib.last path);
  in
    hints.keyring or false
    || secretContainer
    || contains ["apikey" "authorization" "clientsecret" "credential" "credentials" "passwd" "password" "pat" "privatekey" "secret" "token" "tokens"] parts
    || parts == ["access" "key"]
    || parts == ["api" "key"]
    || parts == ["private" "key"];
}

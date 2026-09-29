# cspell:ignore accesskey apikey clientsecret
{lib}: let
  # These final segments name a locator or an environment variable, rather
  # than the payload. Explicit hints and secret containers still win.
  locatorSuffixes = ["dir" "env" "file" "helper" "path" "url" "var"];
  exceptions = [
    ["signing" "key"]
    ["token" "limit"]
  ];
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
    builtins.filter (segment: segment != "") (lib.splitString "_" (lib.toLower (lib.replaceStrings ["-" "."] ["_" "_"] normalized)));
  contains = values: parts: lib.any (part: builtins.elem part values) parts;
in {
  inherit exceptions;
  classify = {
    path,
    hints ? {},
    secretContainer ? false,
  }: let
    parts =
      if path == []
      then []
      else segments (lib.last path);
    last =
      if parts == []
      then ""
      else lib.last parts;
    payload =
      contains ["accesskey" "auth" "authorization" "credential" "credentials" "passwd" "password" "pat" "secret" "token"] parts
      || (builtins.elem "api" parts && builtins.elem "key" parts)
      || (builtins.elem "client" parts && builtins.elem "secret" parts)
      || (builtins.elem "private" parts && builtins.elem "key" parts)
      || contains ["apikey" "clientsecret" "privatekey"] parts;
  in
    if hints.keyring or false || hints.secret or false || secretContainer
    then "secret"
    else if builtins.elem parts exceptions || builtins.elem last locatorSuffixes || last == "tokens"
    then "sensitive"
    else if payload
    then "secret"
    else "sensitive";
}

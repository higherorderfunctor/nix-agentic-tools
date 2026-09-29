# cspell:ignore accesskey apikey clientsecret
{lib}: let
  # A locator is exceptional only when its entire stem is one credential
  # name. An independent credential segment (client_secret_file, for example)
  # still denotes a secret-bearing option.
  locatorSuffixes = ["dir" "env" "file" "helper" "path" "url" "var"];
  locatorStems = ["apikey" "authorization" "credential" "credentials" "password" "privatekey" "secret" "token" "tokens"];
  exceptions = [
    ["max" "tokens"]
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
in rec {
  inherit exceptions;
  classifyPath = path: secretContainer:
    (lib.foldl' (state: name: let
        here = state.path ++ [name];
      in {
        path = here;
        secret =
          classify {
            path = here;
            secretContainer = state.secret;
          }
          == "secret";
      }) {
        path = [];
        secret = secretContainer;
      }
      path).secret;

  classify = {
    path,
    hints ? {},
    secretContainer ? false,
  }: let
    parts =
      if path == []
      then []
      else segments (lib.last path);
    locator =
      builtins.length parts
      == 2
      && builtins.elem (builtins.head parts) locatorStems
      && builtins.elem (lib.last parts) locatorSuffixes;
    apiLocator =
      builtins.length parts
      == 3
      && lib.take 2 parts == ["api" "key"]
      && builtins.elem (lib.last parts) locatorSuffixes;
    privateKeyLocator =
      builtins.length parts
      == 3
      && lib.take 2 parts == ["private" "key"]
      && builtins.elem (lib.last parts) locatorSuffixes;
    environmentLocator =
      builtins.length parts
      == 3
      && builtins.elem (builtins.head parts) locatorStems
      && lib.drop 1 parts == ["env" "var"];
    payload =
      contains ["accesskey" "auth" "authorization" "credential" "credentials" "passwd" "password" "pat" "secret" "token" "tokens"] parts
      || parts == ["access" "tokens"]
      || (builtins.elem "api" parts && builtins.elem "key" parts)
      || (builtins.elem "client" parts && builtins.elem "secret" parts)
      || (builtins.elem "private" parts && builtins.elem "key" parts)
      || contains ["apikey" "clientsecret" "privatekey"] parts;
  in
    if hints.keyring or false || hints.secret or false || secretContainer
    then "secret"
    else if builtins.elem parts exceptions || locator || apiLocator || privateKeyLocator || environmentLocator
    then "sensitive"
    else if payload
    then "secret"
    else "sensitive";
}

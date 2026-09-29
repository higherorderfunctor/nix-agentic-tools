# cspell:ignore accesskey apikey apikeyhelper clientsecret credentialhelper passwordfile signingkey signingkeypath tokenenvvar tokenfile
{lib}: let
  # Locators and names describe how to obtain a secret, not its payload.
  exceptions = ["apikeyhelper" "credentialhelper" "passwordfile" "signingkey" "signingkeypath" "tokenenvvar" "tokenfile"];
  normalize = name: lib.toLower (lib.replaceStrings ["_" "-" "."] ["" "" ""] name);
in {
  inherit exceptions;
  classify = {
    path,
    hints ? {},
    secretContainer ? false,
  }: let
    name = normalize (lib.last path);
  in
    if hints.keyring or false || hints.secret or false || secretContainer
    then "secret"
    else if builtins.elem name exceptions
    then "sensitive"
    else if builtins.elem name ["pat" "auth" "accesskey"]
    then "secret"
    else if builtins.match ".*(token|password|passwd|apikey|clientsecret|authorization|credential|privatekey|secret).*" name != null
    then "secret"
    else "sensitive";
}

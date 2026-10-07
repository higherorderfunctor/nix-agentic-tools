# cspell:ignore apikey clientsecret privatekey
# Callers classify a name whose value is a string (Codex flags with a value,
# string leaves of JSON/settings) or a string-to-string map container such as
# Kimchi's gitTokens; never a struct object or a boolean node.
{lib}: let
  secretSuffixes = [
    "access_key"
    "api_key"
    "apikey"
    "authorization"
    "clientsecret"
    "credential"
    "credentials"
    "git_tokens"
    "passwd"
    "password"
    "pat"
    "private_key"
    "privatekey"
    "secret"
    "secret_key"
    "token"
  ];
  snake = name:
    lib.concatMapStrings (part:
      if builtins.isList part
      then lib.concatStringsSep "_" part
      else part)
    (builtins.split "([a-z0-9])([A-Z])" name);
in {
  classify = {
    hints ? {},
    path,
    secretContainer ? false,
  }: let
    lowered = lib.toLower (lib.replaceStrings ["-" "."] ["_" "_"] (snake (
      if path == []
      then ""
      else lib.last path
    )));
  in
    hints.keyring or false
    || secretContainer
    || lib.any (suffix: lib.hasSuffix "_${suffix}" ("_" + lowered)) secretSuffixes;
}

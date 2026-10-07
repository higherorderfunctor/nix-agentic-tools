# cspell:ignore apikey clientsecret privatekey
# Callers classify only names whose value is a string: Codex flags with
# valueName != null and string leaves of JSON/settings, never object or boolean nodes.
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

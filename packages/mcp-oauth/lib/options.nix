# Credential and scope declarations shared by accounts and mounted owners.
{lib}: let
  redact = import ../../../lib/redact {inherit lib;};
  # Keep rejected credential values out of module-system error rendering.
  credentialType =
    redact.types.redacted
    // {
      merge = loc: defs: let
        value = redact.types.redacted.merge loc defs;
      in
        if redact.isReference value && value._redact ? file
        then value
        else throw "${lib.showOption loc}: requires a credential file reference";
    };
  scopeType = lib.types.strMatching "[A-Za-z0-9:._/-]+";
in {
  inherit scopeType;
  safeNames = accounts:
    lib.mapAttrs (name: value:
      if builtins.match "[a-z0-9][a-z0-9_-]*" name == null
      then throw "OAuth: unsafe account or instance ID"
      else value)
    accounts;
  credentials = {scopesDefault ? null}: {
    clientId = lib.mkOption {
      type = credentialType;
      description = "File reference for the sops client ID secret.";
    };
    clientSecret = lib.mkOption {
      type = credentialType;
      description = "File reference for the sops client secret.";
    };
    scopes = lib.mkOption ({
        type = lib.types.nonEmptyListOf scopeType;
        description = "Requested account scopes.";
      }
      // lib.optionalAttrs (scopesDefault != null) {default = scopesDefault;});
  };
  distinctCredentials = value:
    if value.clientId == value.clientSecret
    then throw "OAuth: two distinct credential files required"
    else value;
}

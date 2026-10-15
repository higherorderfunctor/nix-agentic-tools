# Callers classify string leaves or string-to-string containers, never struct
# objects or boolean nodes. Keep this API for facts and annotation reconciliation;
# key-name patterns and their reasons belong to the generic open-key policy.
{lib}: let
  inherit (import ../open-keys {inherit lib;}) credentialReason;
in {
  classify = {
    hints ? {},
    path,
    secretContainer ? false,
  }:
    hints.keyring or false
    || secretContainer
    || credentialReason (
      if path == []
      then ""
      else lib.last path
    )
    != null;
}

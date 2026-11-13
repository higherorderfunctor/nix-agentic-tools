# Shared metadata for the manifest, service references and state claims.
{lib}: {
  accounts,
  backend,
  stateRoot,
}:
lib.mapAttrs (name: account: {
  client_id_file = account.clientId._redact.file;
  client_secret_file = account.clientSecret._redact.file;
  redirect_uri = account.redirectUri;
  inherit (account) provider scopes;
  state_dir = "${stateRoot}/mcp-oauth/${backend}/${name}";
}) (lib.filterAttrs (_: account: account.enable) accounts)

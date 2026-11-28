# cspell:ignore apikey clientsecret notoken privatekey
{
  harness,
  lib,
  ...
}: let
  inherit (import ../../lib/redact/classify.nix {inherit lib;}) classify;
  checkName = name: expected: classify {path = [name];} == expected;
  nameCases = {
    # Separate policy entries, including legacy spellings and names with one
    # purpose-specific key suffix rather than a generic `key` rule.
    "access_key requires a reference" = checkName "access_key" true;
    "apikey is still a credential without a word boundary" = checkName "apikey" true;
    "authorization is a credential without a key suffix" = checkName "authorization" true;
    "clientsecret is still a credential without a word boundary" = checkName "clientsecret" true;
    "CPA_MANAGEMENT_KEY is secret even with an environment prefix" = checkName "CPA_MANAGEMENT_KEY" true;
    "CPA_MANAGER_ADMIN_KEY authenticates rather than names a file" = checkName "CPA_MANAGER_ADMIN_KEY" true;
    "CPA_MANAGER_DATA_KEY is secret even though it is not a token" = checkName "CPA_MANAGER_DATA_KEY" true;
    "credential singular requires a reference" = checkName "credential" true;
    "credentials plural requires a reference" = checkName "credentials" true;
    "passwd is not treated as a public name" = checkName "passwd" true;
    "password requires a reference independently of passwd" = checkName "password" true;
    "pat is a credential even without the full words" = checkName "pat" true;
    "private_key is secret in underscored form" = checkName "private_key" true;
    "privatekey is secret even without a word boundary" = checkName "privatekey" true;
    "secret is a credential without a key suffix" = checkName "secret" true;
    "secretKey is secret in camel case" = checkName "secretKey" true;

    # Normalization must find suffixes without broadening to arbitrary
    # substrings, prefixes, plural token counters, or generic key metadata.
    "--api-key finds a hyphen-delimited suffix" = checkName "--api-key" true;
    "absorb.token finds a dot-delimited suffix" = checkName "absorb.token" true;
    "IDToken splits a leading acronym before its token suffix" = checkName "IDToken" true;
    "myAPIToken splits an acronym before its title-case suffix" = checkName "myAPIToken" true;

    # Paths and non-credential metadata stay visible; only the value is secret.
    "adminKeyFile is public even in camel case" = checkName "adminKeyFile" false;
    "CPA_MANAGEMENT_KEY_FILE is not the management key itself" = checkName "CPA_MANAGEMENT_KEY_FILE" false;
    "has-metadata-key is not secret just because it ends in key" = checkName "has-metadata-key" false;
    "keepRecentTokens remains a public retention count" = checkName "keepRecentTokens" false;
    "notoken does not match without a suffix boundary" = checkName "notoken" false;
    "tokenEndpoint is public even with a credential prefix" = checkName "tokenEndpoint" false;
  };
  contextCases = {
    "keyring hint on a public leaf" =
      classify {
        hints.keyring = true;
        path = ["host"];
      }
      == true;
    "nested credential leaf does not require a credential parent" = classify {path = ["host" "token"];} == true;
    "only the last path component is a candidate" = classify {path = ["token" "host"];} == false;
    "public leaf with keyring disabled" =
      classify {
        hints.keyring = false;
        path = ["host"];
      }
      == false;
  };
in {
  checks.redact-classifier = harness.mkTest "redact-classifier" (
    harness.checkRows "redaction context" contextCases
    && harness.checkRows "credential name" nameCases
  );
}

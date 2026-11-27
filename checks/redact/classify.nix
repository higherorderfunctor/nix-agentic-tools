# cspell:ignore apikey clientsecret privatekey
{
  harness,
  lib,
  ...
}: let
  inherit (import ../../lib/redact/classify.nix {inherit lib;}) classify;
  cases = {
    "--api-key" = true;
    "absorb.token" = true;
    access_key = true;
    adminKeyFile = false;
    apiKey = true;
    api_key = true;
    apikey = true;
    authorization = true;
    CASTAI_API_KEY = true;
    check_update = false;
    CI_JOB_TOKEN = true;
    client_key = false;
    clientsecret = true;
    configDir = false;
    CPA_MANAGEMENT_KEY = true;
    CPA_MANAGEMENT_KEY_FILE = false;
    CPA_MANAGER_ADMIN_KEY = true;
    CPA_MANAGER_DATA_KEY = true;
    CPA_MANAGER_DATA_KEY_PATH = false;
    credential = true;
    credentials = true;
    deviceId = false;
    extraSettings = false;
    GITLAB_HOST = false;
    gitTokens = true;
    GLAB_CONFIG_DIR = false;
    has-metadata-key = false;
    host = false;
    IDToken = true;
    job_token = true;
    JWTSecret = true;
    keepRecentTokens = false;
    KIMCHI_API_KEY = true;
    managementKey = true;
    maxTokens = false;
    myAPIToken = true;
    oauth2_refresh_token = true;
    passwd = true;
    password = true;
    pat = true;
    private_key = true;
    privatekey = true;
    providerAccessKey = true;
    provider_private_key = true;
    refresh_token = true;
    secret = true;
    SECRET_KEY = true;
    secretKey = true;
    selfHostedUrl = false;
    SORT_KEY = false;
    token = true;
    tokenEndpoint = false;
    "toolSearch.minTokens" = false;
  };
  contextCases = {
    "empty path, no hint" = classify {path = [];} == false;
    "keyring hint on a public leaf" =
      classify {
        hints.keyring = true;
        path = ["host"];
      }
      == true;
    "keyring hint without a path" =
      classify {
        hints.keyring = true;
        path = [];
      }
      == true;
    "only the last path component is a candidate" = classify {path = ["token" "host"];} == false;
    "public leaf with keyring disabled" =
      classify {
        hints.keyring = false;
        path = ["host"];
      }
      == false;
    "secret container with a public name" =
      classify {
        path = ["host"];
        secretContainer = true;
      }
      == true;
  };
in {
  checks.redact-classifier = harness.mkTest "redact-classifier" (
    harness.checkRows "redaction context" contextCases
    && harness.checkRows "credential name" (lib.mapAttrs (name: expected: classify {path = [name];} == expected) cases)
  );
}

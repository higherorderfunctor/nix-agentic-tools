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
  contextCases = [
    {
      expected = false;
      input.path = [];
    }
    {
      expected = true;
      input = {
        hints.keyring = true;
        path = [];
      };
    }
    {
      expected = false;
      input = {
        hints.keyring = false;
        path = ["host"];
      };
    }
    {
      expected = true;
      input = {
        hints.keyring = true;
        path = ["host"];
      };
    }
    {
      expected = true;
      input = {
        path = ["host"];
        secretContainer = true;
      };
    }
    {
      expected = false;
      input.path = ["token" "host"];
    }
  ];
  expectations =
    lib.mapAttrsToList (name: expected: {
      inherit expected;
      input.path = [name];
    })
    cases
    ++ contextCases;
  mismatches = builtins.filter (entry: classify entry.input != entry.expected) expectations;
in {
  checks.redact-classifier = harness.mkTest "redact-classifier" (
    assert lib.assertMsg (mismatches == []) (builtins.toJSON mismatches); true
  );
}

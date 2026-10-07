# cspell:ignore apikey clientsecret privatekey
{
  harness,
  lib,
  self,
  ...
}: let
  inherit (self.lib.runtimeValues) classify;
  cases = {
    "--api-key" = true;
    "absorb.token" = true;
    access_key = true;
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
    credential = true;
    credentials = true;
    deviceId = false;
    extraSettings = false;
    GITLAB_HOST = false;
    gitTokens = true;
    GLAB_CONFIG_DIR = false;
    host = false;
    job_token = true;
    KIMCHI_API_KEY = true;
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
    selfHostedUrl = false;
    token = true;
    tokenEndpoint = false;
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
in {
  checks.runtime-values-classifier = harness.mkTest "runtime-values-classifier" (
    lib.all (name: classify {path = [name];} == cases.${name}) (builtins.attrNames cases)
    && lib.all (entry: classify entry.input == entry.expected) contextCases
  );
}

{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) mcpLib mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  consumer = pkgs.writeScriptBin "mcp-redact-consumer" ''
    #!${pkgs.python3}/bin/python3
    import os
    from pathlib import Path
    value = Path("value").read_text()
    keys = ["CONTEXT7_API_KEY", "GITHUB_PERSONAL_ACCESS_TOKEN", "GITLAB_PERSONAL_ACCESS_TOKEN", "KAGI_API_KEY", "TEST_TOKEN"]
    assert any(os.environ.get(key) == value for key in keys)
    if "GITLAB_PERSONAL_ACCESS_TOKEN" in os.environ:
        assert os.environ["GITLAB_API_URL"] == value
    Path("argv").write_bytes(Path("/proc/self/cmdline").read_bytes())
    print("consumer-ran")
  '';
  packaged = packages:
    map (name:
      mcpLib.renderServer packages name {
        package = consumer;
        settings =
          if name == "gitlab-mcp"
          then {
            instanceUrl = redact.file {path = "/redact-test/value";};
            pat = redact.file {path = "/redact-test/value";};
          }
          else {credentials = redact.file {path = "/redact-test/value";};};
      }) ["context7-mcp" "github-mcp" "gitlab-mcp" "kagi-mcp"];
  packagedEntries = packaged pkgs;
  render = packages: env:
    mcpLib.renderServer packages "probe" {
      command = lib.getExe consumer;
      inherit env;
    };
  fileEntry = render pkgs {TEST_TOKEN = redact.file {path = "/redact-test/value";};};
  commandEntry = render pkgs {TEST_TOKEN = redact.command {path = "/redact-test/helper";};};
  # Inspect the same emitted wrapper text without building or reading store files.
  textPkgs = pkgs // {writeShellScript = _: text: text;};
  wrapperTexts = map (entry: entry.command) (packaged textPkgs
    ++ [
      (render textPkgs {TEST_TOKEN = redact.file {path = "/redact-test/value";};})
      (render textPkgs {TEST_TOKEN = redact.command {path = "/redact-test/helper";};})
    ]);
  referencesOnly =
    lib.all (label: lib.any (text: lib.hasInfix label text) wrapperTexts)
    ["mcpServers.context7-mcp.settings.credentials" "mcpServers.github-mcp.settings.credentials" "mcpServers.gitlab-mcp.settings.instanceUrl" "mcpServers.gitlab-mcp.settings.pat" "mcpServers.kagi-mcp.settings.credentials" "mcpServers.probe.env.TEST_TOKEN"]
    && lib.all (text:
      lib.hasInfix "redact-read" text
      && lib.hasInfix "/redact-test/" text
      && lib.all (target:
        !(lib.hasInfix "${target}=" text)
        || (lib.hasInfix (target + "=\"$(") text
          && builtins.length (lib.splitString "${target}=" text) == 2))
      ["CONTEXT7_API_KEY" "GITHUB_PERSONAL_ACCESS_TOKEN" "GITLAB_API_URL" "GITLAB_PERSONAL_ACCESS_TOKEN" "KAGI_API_KEY" "TEST_TOKEN"])
    wrapperTexts;
in {
  checks = {
    module-mcp-environment-literal-secret-rejected = mkTest "mcp-environment-literal-secret-rejected" (!(builtins.tryEval (builtins.deepSeq (render pkgs {TEST_TOKEN = "forbidden";}) true)).success);
    module-mcp-environment-public-literal = mkTest "mcp-environment-public-literal" (
      (render pkgs {HOST = "public.example";}).env.HOST == "public.example"
    );
    module-mcp-redact-runtime = assert referencesOnly;
      pkgs.runCommand "module-mcp-redact-runtime" {
        nativeBuildInputs = [pkgs.gnugrep pkgs.gnused pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Generate the sentinel only at execution, never in a derivation input.
        secret="mcp-private-$(cat /proc/sys/kernel/random/uuid)"
        printf '%s' "$secret" > value
        for source in ${lib.escapeShellArgs (map (entry: entry.command) (packagedEntries ++ [fileEntry]))}; do
          sed "s|/redact-test|$PWD|g" "$source" > file-runner
          ${pkgs.bash}/bin/bash file-runner > stdout 2> stderr
          grep -Fx consumer-ran stdout
          if grep -Fq "$secret" argv stdout stderr; then echo "leak: MCP argv, stdout or stderr" >&2; exit 1; fi
        done
        sed "s|/redact-test|$PWD|g" ${commandEntry.command} > command-runner
        cat > helper <<'SH'
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.coreutils}/bin/cat value
        ${pkgs.coreutils}/bin/cat value >&2
        exit 1
        SH
        chmod +x helper
        if ${pkgs.bash}/bin/bash command-runner > stdout 2> stderr; then
          echo 'failed command reference unexpectedly ran consumer' >&2
          exit 1
        fi
        if grep -Fq "consumer-ran" stdout stderr; then echo "leak: consumer-ran after failed reference" >&2; exit 1; fi
        if grep -Fq "$secret" stdout stderr; then echo "leak: MCP stdout or stderr" >&2; exit 1; fi
        grep -F 'mcpServers.probe.env.TEST_TOKEN' stderr
        touch "$out"
      '';
  };
}

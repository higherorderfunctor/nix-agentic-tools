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
    assert value.encode() not in Path("/proc/self/cmdline").read_bytes()
    print("consumer-ran")
  '';
  packagedEntries = map (name:
    mcpLib.renderServer pkgs name {
      package = consumer;
      settings =
        if name == "gitlab-mcp"
        then {
          instanceUrl = redact.file {path = "/redact-test/value";};
          pat = redact.file {path = "/redact-test/value";};
        }
        else {credentials = redact.file {path = "/redact-test/value";};};
    }) ["context7-mcp" "github-mcp" "gitlab-mcp" "kagi-mcp"];
  render = env:
    mcpLib.renderServer pkgs "probe" {
      command = lib.getExe consumer;
      inherit env;
    };
  fileEntry = render {TEST_TOKEN = redact.file {path = "/redact-test/value";};};
  commandEntry = render {TEST_TOKEN = redact.command {path = "/redact-test/helper";};};
in {
  checks = {
    module-mcp-environment-literal-secret-rejected = mkTest "mcp-environment-literal-secret-rejected" (!(builtins.tryEval (builtins.deepSeq (render {TEST_TOKEN = "forbidden";}) true)).success);
    module-mcp-environment-public-literal = mkTest "mcp-environment-public-literal" (
      (render {HOST = "public.example";}).env.HOST == "public.example"
    );
    module-mcp-redact-runtime =
      pkgs.runCommand "module-mcp-redact-runtime" {
        nativeBuildInputs = [pkgs.gnugrep pkgs.gnused pkgs.python3];
        plan = builtins.toJSON {inherit commandEntry fileEntry packagedEntries;};
        passAsFile = ["plan"];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Generate the sentinel only at execution, never in a derivation input.
        secret="mcp-private-$(cat /proc/sys/kernel/random/uuid)"
        printf '%s' "$secret" > value
        for source in ${fileEntry.command} ${commandEntry.command}; do
          ! grep -F "$secret" "$source" "$planPath"
        done
        for source in ${lib.escapeShellArgs (map (entry: entry.command) (packagedEntries ++ [fileEntry]))}; do
          ! grep -F "$secret" "$source"
          sed "s|/redact-test|$PWD|g" "$source" > file-runner
          ${pkgs.bash}/bin/bash file-runner > stdout 2> stderr
          grep -Fx consumer-ran stdout
          ! grep -F "$secret" stdout stderr
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
        ! grep -F consumer-ran stdout stderr
        ! grep -F "$secret" stdout stderr
        grep -F 'mcpServers.probe.env.TEST_TOKEN' stderr
        touch "$out"
      '';
  };
}

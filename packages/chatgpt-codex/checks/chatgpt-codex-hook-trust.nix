# cspell:ignore cwds
# Runtime contract: the hook trust Nix derives is the trust the pinned Codex
# computes.
#
# Codex runs a user or project hook only while `hooks.state."<key>"` carries
# the hook's current hash, and its own `/hooks` cannot record that into a
# Nix-owned config.toml, so mkCodex.nix derives the key and the hash for every
# generated handler (`hookTrustFor`). Both reproduce Codex internals: the key
# format and the normalization and hashing of a handler. This check asks the
# pinned binary, through its app-server's `hooks/list`, and fails the update PR
# of a Codex release that changes either.
#
# Home Manager's state is in user config.toml; devenv's is in the launcher's
# `--config` flag, so that half runs the built launcher. The handlers cover
# every normalization Codex applies: a matcher on an event that ignores it,
# default and clamped timeouts, `async`, a status message, a Windows command,
# and a context limit that is kept, dropped at its default, and ignored on an
# event that cannot emit context. The module is evaluated at placeholder roots,
# which are rewritten to the build directory. Offline and with no model call.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  homePlaceholder = "/nat-codex-hook-home";
  rootPlaceholder = "/nat-codex-hook-root";
  declaration.ai = {
    codex = {
      enable = true;
      hooks = {
        Interrupt = [{hooks = [{command = "echo interrupt";}];}];
        PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                additionalContextLimit = 4096;
                async = true;
                command = "echo pre";
                commandWindows = "echo.exe pre";
                statusMessage.text = "Checking";
                timeout = 5;
              }
              {
                additionalContextLimit = 2500;
                command = "echo default-limit";
              }
            ];
          }
        ];
        SessionEnd = [
          {
            hooks = [
              {command = "echo end";}
              {
                command = "echo clamped";
                timeout = 30;
              }
            ];
          }
        ];
        Stop = [
          {
            matcher = "ignored";
            hooks = [
              {
                additionalContextLimit = 10;
                command = "echo stop";
              }
            ];
          }
        ];
      };
    };
    hooks.SessionStart = [
      {hooks = [{command = "echo start";}];}
      {
        matcher = "startup";
        hooks = [{command = "echo second-group";}];
      }
    ];
  };
  hm = (harness.evalHm (lib.recursiveUpdate declaration {home.homeDirectory = homePlaceholder;})).config;
  devenv = (harness.evalDevenv (lib.recursiveUpdate declaration {devenv.root = rootPlaceholder;})).config;
  hmState = hm.ai.codex.files.".codex/config.toml".content.value.hooks.state;
  expected = pkgs.writeText "codex-hook-trust-expected.json" (builtins.toJSON hmState);
  list = pkgs.writeText "codex-hooks-list.py" ''
    import json
    import os
    import subprocess
    import sys

    codex, cwd, source, placeholder, root = sys.argv[1:6]
    expected = json.load(open(os.environ["expected"]))
    # A missing async field would change both hashes in step, so the hash
    # comparison alone cannot prove this authored handler option survives.
    with open(f"{root}/hooks.json") as fixture:
        pre_tool_use = json.load(fixture)["hooks"]["PreToolUse"][0]["hooks"][0]
    if pre_tool_use.get("async") is not True:
        sys.exit(f"FAIL: {source} hooks: rendered PreToolUse handler dropped async=true")
    process = subprocess.Popen(
        [codex, "app-server"], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    )

    def call(request_id, method, params):
        process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        for line in process.stdout:
            message = json.loads(line)
            if message.get("id") == request_id:
                if "error" in message:
                    sys.exit(f"FAIL: {method}: {message['error']}")
                return message["result"]
        sys.exit(f"FAIL: the app-server exited before answering {method}")

    call(1, "initialize", {"clientInfo": {"name": "chatgpt-codex-hook-trust", "version": "0"}})
    process.stdin.write(json.dumps({"method": "initialized"}) + "\n")
    listing = call(2, "hooks/list", {"cwds": [cwd]})
    process.stdin.close()
    process.terminate()

    hooks = [hook for entry in listing["data"] for hook in entry["hooks"] if hook["source"] == source]
    # Pin the declaration's members independently: otherwise a handler omitted
    # from both the rendered JSON and trust state would pass.
    scenarios = {
        "interrupt:0:0": "Interrupt uses the short default timeout",
        "pre_tool_use:0:0": "the matcher, async, status, explicit timeout and nondefault limit are hashed, not the Windows command",
        "pre_tool_use:0:1": "a second handler's default context limit is omitted from its hash",
        "session_end:0:0": "SessionEnd uses the short default timeout",
        "session_end:0:1": "SessionEnd clamps an oversized timeout",
        "session_start:0:0": "the unfiltered shared group keeps its own index",
        "session_start:1:0": "the matched shared group does not overwrite group zero",
        "stop:0:0": "Stop excludes its unused matcher and context limit from the hash",
    }
    derived = {key.replace(placeholder, root, 1): state["trusted_hash"] for key, state in expected.items()}
    listed = {hook["key"]: hook["currentHash"] for hook in hooks}
    members = {f"{root}/hooks.json:{suffix}" for suffix in scenarios}
    if listed.keys() != members or len(hooks) != len(members):
        sys.exit(f"FAIL: {source} hooks: expected {sorted(members)}, got {[hook['key'] for hook in hooks]}")
    if derived.keys() != members:
        sys.exit(f"FAIL: {source} hooks: Nix derived unexpected trust members {sorted(derived)}")
    for suffix, scenario in scenarios.items():
        key = f"{root}/hooks.json:{suffix}"
        if listed[key] != derived[key]:
            sys.exit(f"FAIL: {source} {scenario}: {key} has Codex hash {listed[key]}, Nix derived {derived[key]}")
    untrusted = [hook["key"] for hook in hooks if hook["trustStatus"] != "trusted"]
    if untrusted:
        sys.exit(f"FAIL: {source} hooks Codex does not trust: {untrusted}")
    print(f"ok: {len(hooks)} {source} hooks trusted")
  '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    chatgpt-codex-hook-trust =
      pkgs.runCommand "chatgpt-codex-hook-trust" {
        inherit expected;
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Home Manager: user hooks.json and the state in user config.toml.
        export HOME="$TMPDIR/home"
        export CODEX_HOME="$HOME/.codex"
        mkdir -p "$CODEX_HOME" "$TMPDIR/work"
        cp ${hm.home.file.".codex/hooks.json".source} "$CODEX_HOME/hooks.json"
        sed 's|${homePlaceholder}|'"$HOME"'|g' ${hm.home.file.".codex/config.toml".source} > "$CODEX_HOME/config.toml"
        timeout 120 python3 ${list} ${harness.aiStubs.chatgpt-codex}/bin/codex "$TMPDIR/work" user \
          ${homePlaceholder}/.codex "$CODEX_HOME"

        # devenv: project hooks.json in a trusted project, and the state in
        # the launcher's session flag. The project's trust stands in for the
        # user's own Home Manager declaration.
        project="$TMPDIR/project"
        export HOME="$TMPDIR/devenv-home"
        export CODEX_HOME="$HOME/.codex"
        mkdir -p "$CODEX_HOME" "$project/.codex"
        cp ${devenv.files.".codex/hooks.json".source} "$project/.codex/hooks.json"
        printf '[projects."%s"]\ntrust_level = "trusted"\n' "$project" > "$CODEX_HOME/config.toml"
        sed 's|${rootPlaceholder}|'"$project"'|g' ${lib.head devenv.packages}/bin/codex > "$TMPDIR/codex"
        chmod +x "$TMPDIR/codex"
        timeout 120 python3 ${list} "$TMPDIR/codex" "$project" project \
          ${homePlaceholder}/.codex "$project/.codex"
        echo "ok: Codex trusts every hook Nix generates, on both backends" > "$out"
      '';
  };
}
